begin;

create type public.attempt_status as enum (
  'started', 'succeeded', 'failed', 'timed_out', 'cancelled', 'superseded'
);
create type public.delivery_status as enum (
  'pending', 'ready', 'delivering', 'delivered', 'failed', 'cancelled'
);
create type public.failure_class as enum (
  'transient', 'rate_limited', 'invalid_input', 'policy', 'permission', 'dependency', 'bug', 'unknown'
);

alter table public.work_items
  add column queue text not null default 'default',
  add column trace_id uuid not null default gen_random_uuid(),
  add column workflow_name text,
  add column workflow_version text,
  add column policy_version text,
  add column prompt_version text,
  add column toolset_version text,
  add column lease_token uuid,
  add column lease_version bigint not null default 0,
  add column failure_class public.failure_class,
  add column cancellation_requested_at timestamptz,
  add column paused_at timestamptz;

create index work_items_queue_claim_idx
  on public.work_items (queue, priority desc, available_at, created_at)
  where status = 'queued';
create index work_items_trace_idx on public.work_items (trace_id);

create table public.work_attempts (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid not null references public.work_items(id) on delete cascade,
  attempt_number integer not null check (attempt_number > 0),
  agent_id uuid references public.agents(id) on delete set null,
  trace_id uuid not null,
  span_id uuid not null default gen_random_uuid(),
  lease_token uuid not null,
  lease_version bigint not null,
  status public.attempt_status not null default 'started',
  model_provider text,
  model_name text,
  prompt_version text,
  toolset_version text,
  policy_version text,
  input_snapshot jsonb not null default '{}',
  output_snapshot jsonb,
  error jsonb,
  started_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now(),
  ended_at timestamptz,
  unique (work_item_id, attempt_number),
  unique (lease_token)
);

create index work_attempts_active_idx
  on public.work_attempts (agent_id, heartbeat_at)
  where status = 'started';
create index work_attempts_trace_idx on public.work_attempts (trace_id, started_at);

create table public.policy_versions (
  id uuid primary key default gen_random_uuid(),
  policy_name text not null,
  version text not null,
  document jsonb not null,
  document_sha256 text not null,
  is_active boolean not null default false,
  created_by text not null,
  created_at timestamptz not null default now(),
  unique (policy_name, version)
);

create unique index one_active_policy_version
  on public.policy_versions (policy_name)
  where is_active;

create or replace function public.hash_policy_document()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.document_sha256 = encode(digest(convert_to(new.document::text, 'UTF8'), 'sha256'), 'hex');
  return new;
end;
$$;

create trigger policy_versions_hash_document
before insert or update of document on public.policy_versions
for each row execute function public.hash_policy_document();

create table public.tool_versions (
  id uuid primary key default gen_random_uuid(),
  tool_name text not null,
  version text not null,
  input_schema jsonb not null,
  output_schema jsonb,
  minimum_authority_level smallint not null default 0 check (minimum_authority_level between 0 and 4),
  risk public.risk_level not null default 'low',
  requires_approval boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tool_name, version)
);

alter table public.approvals
  add column payload_sha256 text;

update public.approvals
set payload_sha256 = encode(digest(convert_to(payload::text, 'UTF8'), 'sha256'), 'hex');

alter table public.approvals
  alter column payload_sha256 set not null;

create or replace function public.protect_approval_payload()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.payload_sha256 = encode(digest(convert_to(new.payload::text, 'UTF8'), 'sha256'), 'hex');
    return new;
  end if;

  if new.work_item_id is distinct from old.work_item_id
     or new.requested_by is distinct from old.requested_by
     or new.action_type is distinct from old.action_type
     or new.summary is distinct from old.summary
     or new.payload is distinct from old.payload
     or new.risk is distinct from old.risk
     or new.expires_at is distinct from old.expires_at
     or new.payload_sha256 is distinct from old.payload_sha256 then
    raise exception 'approval request payload is immutable; create a new approval';
  end if;

  return new;
end;
$$;

create trigger approvals_protect_payload
before insert or update on public.approvals
for each row execute function public.protect_approval_payload();

create table public.control_flags (
  scope text not null,
  key text not null,
  enabled boolean not null default false,
  reason text,
  updated_by text not null,
  updated_at timestamptz not null default now(),
  primary key (scope, key)
);

insert into public.control_flags (scope, key, enabled, reason, updated_by)
values
  ('global', 'work_claims_paused', false, 'Emergency stop for new work claims', 'migration'),
  ('global', 'outbound_actions_disabled', true, 'Remain disabled until human approval flow is tested', 'migration');

create table public.action_outbox (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid not null references public.work_items(id) on delete cascade,
  attempt_id uuid references public.work_attempts(id) on delete set null,
  requested_by uuid references public.agents(id) on delete set null,
  approval_id uuid references public.approvals(id) on delete restrict,
  action_type text not null,
  destination text,
  payload jsonb not null,
  payload_sha256 text not null,
  idempotency_key text not null unique,
  requires_approval boolean not null default true,
  status public.delivery_status not null default 'pending',
  delivery_attempts integer not null default 0 check (delivery_attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error jsonb,
  external_result jsonb,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index action_outbox_delivery_idx
  on public.action_outbox (next_attempt_at, created_at)
  where status in ('ready', 'failed');

create or replace function public.validate_outbox_action()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  approval_record public.approvals;
  calculated_hash text;
begin
  calculated_hash := encode(digest(convert_to(new.payload::text, 'UTF8'), 'sha256'), 'hex');

  if tg_op = 'UPDATE' and (
       new.work_item_id is distinct from old.work_item_id
       or new.attempt_id is distinct from old.attempt_id
       or new.requested_by is distinct from old.requested_by
       or new.approval_id is distinct from old.approval_id
       or new.action_type is distinct from old.action_type
       or new.destination is distinct from old.destination
       or new.payload is distinct from old.payload
       or new.payload_sha256 is distinct from old.payload_sha256
       or new.idempotency_key is distinct from old.idempotency_key
       or new.requires_approval is distinct from old.requires_approval
     ) then
    raise exception 'outbox action identity and payload are immutable';
  end if;

  if new.payload_sha256 is null then
    new.payload_sha256 := calculated_hash;
  elsif new.payload_sha256 <> calculated_hash then
    raise exception 'outbox payload hash does not match payload';
  end if;

  if new.status in ('ready', 'delivering', 'delivered') and exists (
    select 1 from public.control_flags
    where scope = 'global' and key = 'outbound_actions_disabled' and enabled
  ) then
    raise exception 'outbound actions are disabled by control flag';
  end if;

  if new.requires_approval and new.status in ('ready', 'delivering', 'delivered') then
    if new.approval_id is null then
      raise exception 'approval is required before action delivery';
    end if;

    select * into approval_record from public.approvals where id = new.approval_id;
    if not found then
      raise exception 'approval does not exist';
    end if;
    if approval_record.status <> 'approved' then
      raise exception 'approval is not approved';
    end if;
    if approval_record.work_item_id <> new.work_item_id
       or approval_record.action_type <> new.action_type then
      raise exception 'approval does not match action identity';
    end if;
    if approval_record.payload_sha256 <> new.payload_sha256 then
      raise exception 'approved payload does not match action payload';
    end if;
    if approval_record.expires_at is not null and approval_record.expires_at <= now() then
      raise exception 'approval has expired';
    end if;
  end if;

  return new;
end;
$$;

create trigger action_outbox_validate
before insert or update on public.action_outbox
for each row execute function public.validate_outbox_action();

create trigger action_outbox_set_updated_at
before update on public.action_outbox
for each row execute function public.set_updated_at();

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null check (scope_type in ('global', 'agent', 'workflow', 'customer')),
  scope_id text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  hard_limit_usd numeric(12, 4) not null check (hard_limit_usd >= 0),
  soft_limit_usd numeric(12, 4) check (soft_limit_usd is null or soft_limit_usd between 0 and hard_limit_usd),
  spent_usd numeric(12, 6) not null default 0 check (spent_usd >= 0),
  input_tokens bigint not null default 0 check (input_tokens >= 0),
  output_tokens bigint not null default 0 check (output_tokens >= 0),
  tool_calls bigint not null default 0 check (tool_calls >= 0),
  updated_at timestamptz not null default now(),
  check (period_end > period_start),
  unique (scope_type, scope_id, period_start, period_end)
);

create or replace function public.reserve_budget(
  p_scope_type text,
  p_scope_id text,
  p_cost_usd numeric,
  p_input_tokens bigint default 0,
  p_output_tokens bigint default 0,
  p_tool_calls bigint default 0
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_budget public.budgets;
begin
  if p_cost_usd < 0 or p_input_tokens < 0 or p_output_tokens < 0 or p_tool_calls < 0 then
    raise exception 'budget reservation values must be non-negative';
  end if;

  select * into selected_budget
  from public.budgets
  where scope_type = p_scope_type
    and scope_id = p_scope_id
    and period_start <= now()
    and period_end > now()
  order by period_start desc
  for update
  limit 1;

  if not found then
    return false;
  end if;

  if selected_budget.spent_usd + p_cost_usd > selected_budget.hard_limit_usd then
    return false;
  end if;

  update public.budgets
  set spent_usd = spent_usd + p_cost_usd,
      input_tokens = input_tokens + p_input_tokens,
      output_tokens = output_tokens + p_output_tokens,
      tool_calls = tool_calls + p_tool_calls,
      updated_at = now()
  where id = selected_budget.id;

  return true;
end;
$$;

create table public.usage_ledger (
  id bigint generated always as identity primary key,
  trace_id uuid not null,
  work_item_id uuid references public.work_items(id) on delete set null,
  attempt_id uuid references public.work_attempts(id) on delete set null,
  agent_id uuid references public.agents(id) on delete set null,
  provider text,
  model text,
  tool_name text,
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  cost_usd numeric(12, 6) not null default 0 check (cost_usd >= 0),
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  created_at timestamptz not null default now()
);

create index usage_ledger_trace_idx on public.usage_ledger (trace_id, created_at);

create table public.eval_results (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid references public.work_items(id) on delete cascade,
  attempt_id uuid references public.work_attempts(id) on delete cascade,
  evaluator text not null,
  evaluator_version text not null,
  metric text not null,
  score numeric,
  passed boolean,
  evidence jsonb not null default '{}',
  created_at timestamptz not null default now()
);

alter table public.audit_events
  add column trace_id uuid,
  add column span_id uuid,
  add column attempt_id uuid references public.work_attempts(id) on delete set null,
  add column policy_version text,
  add column prompt_version text,
  add column tool_version text,
  add column data_classification text not null default 'internal'
    check (data_classification in ('public', 'internal', 'confidential', 'restricted')),
  add column redaction_applied boolean not null default false;

create index audit_events_trace_idx on public.audit_events (trace_id, created_at);

create or replace function public.prevent_event_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'event and usage ledgers are append-only';
end;
$$;

create trigger audit_events_append_only
before update or delete on public.audit_events
for each row execute function public.prevent_event_mutation();

create trigger usage_ledger_append_only
before update or delete on public.usage_ledger
for each row execute function public.prevent_event_mutation();

create or replace function public.claim_next_work_item(
  p_agent_id uuid,
  p_capabilities text[],
  p_lease_seconds integer default 900
)
returns public.work_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimed public.work_items;
  new_lease_token uuid := gen_random_uuid();
  new_attempt_number integer;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception 'lease must be between 30 and 3600 seconds';
  end if;

  if exists (
    select 1 from public.control_flags
    where scope = 'global' and key = 'work_claims_paused' and enabled
  ) then
    return null;
  end if;

  select w.* into claimed
  from public.work_items w
  where w.status = 'queued'
    and w.available_at <= now()
    and (w.assigned_to is null or w.assigned_to = p_agent_id)
    and w.required_capabilities <@ p_capabilities
  order by w.priority desc, w.created_at
  for update skip locked
  limit 1;

  if claimed.id is null then
    return null;
  end if;

  select coalesce(max(attempt_number), 0) + 1 into new_attempt_number
  from public.work_attempts
  where work_item_id = claimed.id;

  update public.work_items
  set status = 'claimed',
      assigned_to = p_agent_id,
      claimed_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      lease_token = new_lease_token,
      lease_version = lease_version + 1
  where id = claimed.id
  returning * into claimed;

  insert into public.work_attempts (
    work_item_id, attempt_number, agent_id, trace_id, lease_token, lease_version,
    prompt_version, toolset_version, policy_version, input_snapshot
  ) values (
    claimed.id, new_attempt_number, p_agent_id, claimed.trace_id,
    claimed.lease_token, claimed.lease_version, claimed.prompt_version,
    claimed.toolset_version, claimed.policy_version, claimed.input
  );

  insert into public.audit_events (
    agent_id, work_item_id, trace_id, event_type,
    policy_version, prompt_version
  ) values (
    p_agent_id, claimed.id, claimed.trace_id, 'claimed',
    claimed.policy_version, claimed.prompt_version
  );

  return claimed;
end;
$$;

create or replace function public.requeue_expired_work_items()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  item public.work_items;
  recovered integer := 0;
  next_status public.work_status;
  retry_delay_seconds integer;
begin
  for item in
    select * from public.work_items
    where status in ('claimed', 'running')
      and lease_expires_at < now()
    for update skip locked
  loop
    next_status := case
      when item.retry_count + 1 > item.max_retries then 'dead_letter'::public.work_status
      else 'queued'::public.work_status
    end;
    retry_delay_seconds := least(900, (power(2, item.retry_count)::integer * 5));

    update public.work_attempts
    set status = 'timed_out', ended_at = now(),
        error = jsonb_build_object('type', 'lease_expired')
    where work_item_id = item.id
      and lease_token = item.lease_token
      and status = 'started';

    update public.work_items
    set status = next_status,
        assigned_to = null,
        claimed_at = null,
        lease_expires_at = null,
        lease_token = null,
        retry_count = retry_count + 1,
        failure_class = 'transient',
        available_at = now() + make_interval(secs => retry_delay_seconds)
    where id = item.id;

    insert into public.audit_events (
      agent_id, work_item_id, trace_id, event_type, payload
    ) values (
      item.assigned_to, item.id, item.trace_id, 'lease_expired',
      jsonb_build_object('next_status', next_status, 'retry_delay_seconds', retry_delay_seconds)
    );

    recovered := recovered + 1;
  end loop;

  return recovered;
end;
$$;

create or replace function public.heartbeat_work_attempt(
  p_work_item_id uuid,
  p_agent_id uuid,
  p_lease_token uuid,
  p_lease_version bigint,
  p_extend_seconds integer default 300
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_expiration timestamptz;
begin
  if p_extend_seconds < 30 or p_extend_seconds > 900 then
    raise exception 'heartbeat extension must be between 30 and 900 seconds';
  end if;

  update public.work_items
  set lease_expires_at = greatest(lease_expires_at, now()) + make_interval(secs => p_extend_seconds)
  where id = p_work_item_id
    and assigned_to = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status in ('claimed', 'running')
    and cancellation_requested_at is null
  returning lease_expires_at into new_expiration;

  if new_expiration is null then
    raise exception 'stale, cancelled, or invalid work lease';
  end if;

  update public.work_attempts
  set heartbeat_at = now()
  where work_item_id = p_work_item_id
    and agent_id = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status = 'started';

  return new_expiration;
end;
$$;

create or replace function public.complete_work_attempt(
  p_work_item_id uuid,
  p_agent_id uuid,
  p_lease_token uuid,
  p_lease_version bigint,
  p_output jsonb
)
returns public.work_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  completed public.work_items;
  active_attempt_id uuid;
begin
  select id into active_attempt_id
  from public.work_attempts
  where work_item_id = p_work_item_id
    and agent_id = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status = 'started'
  for update;

  if active_attempt_id is null then
    raise exception 'stale or invalid work attempt';
  end if;

  update public.work_items
  set status = 'completed',
      output = p_output,
      completed_at = now(),
      lease_expires_at = null,
      lease_token = null
  where id = p_work_item_id
    and assigned_to = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status in ('claimed', 'running')
    and cancellation_requested_at is null
  returning * into completed;

  if completed.id is null then
    raise exception 'work lease is no longer current';
  end if;

  update public.work_attempts
  set status = 'succeeded', output_snapshot = p_output, ended_at = now()
  where id = active_attempt_id;

  insert into public.audit_events (
    agent_id, work_item_id, trace_id, attempt_id, event_type
  ) values (
    p_agent_id, completed.id, completed.trace_id, active_attempt_id, 'completed'
  );

  return completed;
end;
$$;

create or replace function public.fail_work_attempt(
  p_work_item_id uuid,
  p_agent_id uuid,
  p_lease_token uuid,
  p_lease_version bigint,
  p_failure_class public.failure_class,
  p_error jsonb,
  p_retryable boolean
)
returns public.work_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  failed public.work_items;
  active_attempt_id uuid;
  next_status public.work_status;
  retry_delay_seconds integer;
begin
  select id into active_attempt_id
  from public.work_attempts
  where work_item_id = p_work_item_id
    and agent_id = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status = 'started'
  for update;

  if active_attempt_id is null then
    raise exception 'stale or invalid work attempt';
  end if;

  select * into failed from public.work_items where id = p_work_item_id for update;
  if failed.assigned_to is distinct from p_agent_id
     or failed.lease_token is distinct from p_lease_token
     or failed.lease_version <> p_lease_version then
    raise exception 'work lease is no longer current';
  end if;

  next_status := case
    when not p_retryable or failed.retry_count + 1 > failed.max_retries
      then 'dead_letter'::public.work_status
    else 'queued'::public.work_status
  end;
  retry_delay_seconds := least(900, (power(2, failed.retry_count)::integer * 5));

  update public.work_attempts
  set status = 'failed', error = p_error, ended_at = now()
  where id = active_attempt_id;

  update public.work_items
  set status = next_status,
      error = p_error,
      failure_class = p_failure_class,
      retry_count = retry_count + 1,
      assigned_to = null,
      claimed_at = null,
      lease_expires_at = null,
      lease_token = null,
      available_at = case
        when next_status = 'queued' then now() + make_interval(secs => retry_delay_seconds)
        else available_at
      end
  where id = p_work_item_id
  returning * into failed;

  insert into public.audit_events (
    agent_id, work_item_id, trace_id, attempt_id, event_type, payload
  ) values (
    p_agent_id, failed.id, failed.trace_id, active_attempt_id, 'failed',
    jsonb_build_object('failure_class', p_failure_class, 'retryable', p_retryable, 'next_status', next_status)
  );

  return failed;
end;
$$;

alter table public.work_attempts enable row level security;
alter table public.policy_versions enable row level security;
alter table public.tool_versions enable row level security;
alter table public.action_outbox enable row level security;
alter table public.control_flags enable row level security;
alter table public.budgets enable row level security;
alter table public.usage_ledger enable row level security;
alter table public.eval_results enable row level security;

revoke all on public.work_attempts from anon, authenticated;
revoke all on public.policy_versions from anon, authenticated;
revoke all on public.tool_versions from anon, authenticated;
revoke all on public.action_outbox from anon, authenticated;
revoke all on public.control_flags from anon, authenticated;
revoke all on public.budgets from anon, authenticated;
revoke all on public.usage_ledger from anon, authenticated;
revoke all on public.eval_results from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

commit;

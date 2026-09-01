begin;

create extension if not exists pgcrypto;

-- Trigger helpers live outside the Data API's exposed schema.
create schema if not exists control_plane_private;
revoke all on schema control_plane_private from public, anon, authenticated, service_role;

create type public.agent_status as enum ('offline', 'idle', 'busy', 'blocked', 'disabled');
create type public.work_status as enum (
  'queued', 'claimed', 'running', 'waiting_approval', 'completed', 'failed', 'dead_letter', 'cancelled'
);
create type public.message_kind as enum ('task', 'result', 'question', 'review', 'system');
create type public.approval_status as enum ('pending', 'approved', 'rejected', 'expired', 'cancelled');
create type public.risk_level as enum ('low', 'medium', 'high', 'critical');

create table public.agents (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  role text not null,
  authority_level smallint not null default 0 check (authority_level between 0 and 4),
  capabilities text[] not null default '{}',
  status public.agent_status not null default 'offline',
  max_concurrency smallint not null default 1 check (max_concurrency between 1 and 20),
  metadata jsonb not null default '{}',
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.agent_credentials (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agents(id) on delete cascade,
  label text not null,
  key_hash text not null unique,
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index agent_credentials_agent_idx on public.agent_credentials (agent_id);

create table public.work_items (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.work_items(id) on delete set null,
  requested_by uuid references public.agents(id) on delete set null,
  assigned_to uuid references public.agents(id) on delete set null,
  work_type text not null,
  title text not null,
  priority smallint not null default 50 check (priority between 0 and 100),
  status public.work_status not null default 'queued',
  required_capabilities text[] not null default '{}',
  input jsonb not null default '{}',
  output jsonb,
  error jsonb,
  idempotency_key text unique,
  retry_count smallint not null default 0,
  max_retries smallint not null default 2 check (max_retries between 0 and 10),
  available_at timestamptz not null default now(),
  due_at timestamptz,
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index work_items_claim_idx
  on public.work_items (priority desc, created_at)
  where status = 'queued';
create index work_items_assignee_idx on public.work_items (assigned_to, status);
create index work_items_parent_idx on public.work_items (parent_id) where parent_id is not null;
create index work_items_requester_idx on public.work_items (requested_by) where requested_by is not null;

create table public.messages (
  id bigint generated always as identity primary key,
  from_agent uuid references public.agents(id) on delete set null,
  to_agent uuid references public.agents(id) on delete cascade,
  work_item_id uuid references public.work_items(id) on delete cascade,
  kind public.message_kind not null,
  body jsonb not null,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  check (to_agent is not null or kind = 'system')
);

create index messages_inbox_idx on public.messages (to_agent, read_at, created_at);
create index messages_sender_idx on public.messages (from_agent) where from_agent is not null;
create index messages_work_item_idx on public.messages (work_item_id) where work_item_id is not null;

create table public.shared_state (
  namespace text not null,
  key text not null,
  value jsonb not null,
  version bigint not null default 1,
  updated_by uuid references public.agents(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (namespace, key)
);

create index shared_state_updated_by_idx on public.shared_state (updated_by) where updated_by is not null;

create table public.artifacts (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid references public.work_items(id) on delete cascade,
  created_by uuid references public.agents(id) on delete set null,
  uri text not null,
  media_type text,
  sha256 text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create index artifacts_work_item_idx on public.artifacts (work_item_id) where work_item_id is not null;
create index artifacts_created_by_idx on public.artifacts (created_by) where created_by is not null;

create table public.approvals (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid not null references public.work_items(id) on delete cascade,
  requested_by uuid references public.agents(id) on delete set null,
  action_type text not null,
  summary text not null,
  payload jsonb not null,
  risk public.risk_level not null,
  status public.approval_status not null default 'pending',
  resolved_by text,
  resolution_notes text,
  expires_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index one_pending_approval_per_action
  on public.approvals (work_item_id, action_type)
  where status = 'pending';
create index approvals_work_item_idx on public.approvals (work_item_id);
create index approvals_requester_idx on public.approvals (requested_by) where requested_by is not null;

create table public.audit_events (
  id bigint generated always as identity primary key,
  agent_id uuid references public.agents(id) on delete set null,
  work_item_id uuid references public.work_items(id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}',
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  estimated_cost_usd numeric(12, 6) check (estimated_cost_usd is null or estimated_cost_usd >= 0),
  created_at timestamptz not null default now()
);

create index audit_events_work_idx on public.audit_events (work_item_id, created_at);
create index audit_events_agent_idx on public.audit_events (agent_id, created_at);

create or replace function control_plane_private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger agents_set_updated_at
before update on public.agents
for each row execute function control_plane_private.set_updated_at();

create trigger work_items_set_updated_at
before update on public.work_items
for each row execute function control_plane_private.set_updated_at();

create or replace function public.claim_next_work_item(
  p_agent_id uuid,
  p_lease_seconds integer default 900
)
returns public.work_items
language plpgsql
security invoker
set search_path = ''
as $$
declare
  claimed public.work_items;
  claiming_agent public.agents;
  active_count integer;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception 'lease must be between 30 and 3600 seconds';
  end if;

  select * into claiming_agent
  from public.agents
  where id = p_agent_id
  for update;

  if not found or claiming_agent.status not in ('idle', 'busy') then
    return null;
  end if;

  select count(*) into active_count
  from public.work_items
  where assigned_to = p_agent_id
    and status in ('claimed', 'running', 'waiting_approval');

  if active_count >= claiming_agent.max_concurrency then
    return null;
  end if;

  select w.* into claimed
  from public.work_items w
  where w.status = 'queued'
    and w.available_at <= now()
    and (w.assigned_to is null or w.assigned_to = p_agent_id)
    and w.required_capabilities <@ claiming_agent.capabilities
  order by w.priority desc, w.created_at
  for update skip locked
  limit 1;

  if claimed.id is null then
    return null;
  end if;

  update public.work_items
  set status = 'claimed',
      assigned_to = p_agent_id,
      claimed_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where id = claimed.id
  returning * into claimed;

  insert into public.audit_events (agent_id, work_item_id, event_type)
  values (p_agent_id, claimed.id, 'claimed');

  update public.agents
  set status = 'busy', last_seen_at = now()
  where id = p_agent_id;

  return claimed;
end;
$$;

create or replace function public.requeue_expired_work_items()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  recovered integer;
begin
  with expired as (
    update public.work_items
    set status = case when retry_count + 1 > max_retries then 'dead_letter'::public.work_status else 'queued'::public.work_status end,
        assigned_to = null,
        claimed_at = null,
        lease_expires_at = null,
        retry_count = retry_count + 1,
        available_at = now()
    where status in ('claimed', 'running')
      and lease_expires_at < now()
    returning id
  )
  select count(*) into recovered from expired;

  return recovered;
end;
$$;

alter table public.agents enable row level security;
alter table public.agent_credentials enable row level security;
alter table public.work_items enable row level security;
alter table public.messages enable row level security;
alter table public.shared_state enable row level security;
alter table public.artifacts enable row level security;
alter table public.approvals enable row level security;
alter table public.audit_events enable row level security;

alter table public.agents force row level security;
alter table public.agent_credentials force row level security;
alter table public.work_items force row level security;
alter table public.messages force row level security;
alter table public.shared_state force row level security;
alter table public.artifacts force row level security;
alter table public.approvals force row level security;
alter table public.audit_events force row level security;

create policy deny_direct_agent_access on public.agents
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.agent_credentials
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.work_items
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.messages
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.shared_state
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.artifacts
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.approvals
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.audit_events
  for all to anon, authenticated using (false) with check (false);

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on function public.claim_next_work_item(uuid, integer) from public, anon, authenticated;
revoke all on function public.requeue_expired_work_items() from public, anon, authenticated;
revoke all on all functions in schema control_plane_private from public, anon, authenticated, service_role;

alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema control_plane_private revoke execute on functions from public, anon, authenticated, service_role;

-- The control-plane API is the only holder of the service-role secret. Agents
-- authenticate to that API and never receive direct database credentials.
grant usage on schema public to service_role;
grant select, insert, update on public.agents to service_role;
grant select, insert, update on public.agent_credentials to service_role;
grant select, insert, update on public.work_items to service_role;
grant select, insert, update on public.messages to service_role;
grant select, insert, update on public.shared_state to service_role;
grant select, insert on public.artifacts to service_role;
grant select, insert, update on public.approvals to service_role;
grant select, insert on public.audit_events to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on function public.claim_next_work_item(uuid, integer) to service_role;
grant execute on function public.requeue_expired_work_items() to service_role;

commit;

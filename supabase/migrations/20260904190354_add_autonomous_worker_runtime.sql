begin;

create extension if not exists pg_cron;

-- VentureOS v0.5: durable worker presence and wake-up signals. A provider
-- routine may wake a worker, but PostgreSQL remains authoritative for work,
-- leases, lineage, retries, and completion.

create table public.worker_environments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations(id) on delete cascade,
  venture_id uuid references public.ventures(id) on delete cascade,
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  slug text not null
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null check (length(trim(name)) between 1 and 160),
  provider text not null check (length(trim(provider)) between 1 and 80),
  runtime_type text not null check (
    runtime_type in (
      'grok_bot', 'hosted_worker', 'persistent_worker', 'managed_microvm',
      'dedicated_host'
    )
  ),
  isolation_level text not null check (
    isolation_level in (
      'shared_account', 'dedicated_identity', 'microvm', 'dedicated_host'
    )
  ),
  attestation_state text not null default 'declared' check (
    attestation_state in ('declared', 'verified', 'failed', 'expired')
  ),
  expected_poll_interval_seconds integer not null default 300
    check (expected_poll_interval_seconds between 30 and 3600),
  missed_poll_threshold smallint not null default 3
    check (missed_poll_threshold between 1 and 20),
  network_policy jsonb not null default '{}',
  tool_policy jsonb not null default '{}',
  status text not null default 'active'
    check (status in ('active', 'paused', 'draining', 'offline', 'retired')),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, slug),
  unique (workspace_id, id)
);

create index worker_environments_watchdog_idx
  on public.worker_environments (status, workspace_id)
  where status in ('active', 'draining');

create table public.agent_runtime_bindings (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  agent_id uuid not null references public.agents(id) on delete cascade,
  environment_id uuid not null,
  runtime_instance_id uuid not null,
  runtime_version text,
  status text not null default 'online'
    check (status in ('online', 'degraded', 'offline', 'paused', 'revoked')),
  last_seen_at timestamptz not null default now(),
  last_poll_at timestamptz,
  last_routine_trigger_at timestamptz,
  missed_poll_count integer not null default 0 check (missed_poll_count >= 0),
  last_error jsonb,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agent_id, environment_id, runtime_instance_id),
  unique (workspace_id, id),
  unique (workspace_id, id, agent_id, environment_id),
  foreign key (workspace_id, agent_id)
    references public.agents(workspace_id, id),
  foreign key (workspace_id, environment_id)
    references public.worker_environments(workspace_id, id)
);

create index agent_runtime_bindings_watchdog_idx
  on public.agent_runtime_bindings (status, last_seen_at)
  where status in ('online', 'degraded');
create index agent_runtime_bindings_agent_idx
  on public.agent_runtime_bindings (workspace_id, agent_id, status);

create table public.dispatch_signals (
  id bigint generated always as identity primary key,
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  environment_id uuid not null,
  runtime_binding_id uuid not null,
  agent_id uuid not null,
  work_item_id uuid references public.work_items(id) on delete cascade,
  signal_type text not null default 'work_available' check (
    signal_type in ('work_available', 'message_available', 'approval_resolved', 'control')
  ),
  status text not null default 'pending' check (
    status in ('pending', 'delivered', 'acknowledged', 'expired', 'failed')
  ),
  idempotency_key text not null,
  available_at timestamptz not null default now(),
  expires_at timestamptz,
  delivered_at timestamptz,
  acknowledged_at timestamptz,
  delivery_attempts integer not null default 0 check (delivery_attempts >= 0),
  last_error jsonb,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, idempotency_key),
  foreign key (workspace_id, environment_id)
    references public.worker_environments(workspace_id, id),
  foreign key (workspace_id, runtime_binding_id)
    references public.agent_runtime_bindings(workspace_id, id),
  foreign key (workspace_id, runtime_binding_id, agent_id, environment_id)
    references public.agent_runtime_bindings(
      workspace_id, id, agent_id, environment_id
    ),
  foreign key (workspace_id, agent_id)
    references public.agents(workspace_id, id),
  foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id)
);

create index dispatch_signals_poll_idx
  on public.dispatch_signals (
    workspace_id, runtime_binding_id, available_at, id
  )
  where status in ('pending', 'delivered');
create index dispatch_signals_work_item_idx
  on public.dispatch_signals (workspace_id, work_item_id)
  where work_item_id is not null;

alter table public.artifacts
  add column name text,
  add column artifact_version integer not null default 1
    check (artifact_version > 0),
  add column byte_size bigint check (byte_size is null or byte_size >= 0),
  add column data_classification text not null default 'internal' check (
    data_classification in ('public', 'internal', 'confidential', 'restricted')
  ),
  add column lifecycle_status text not null default 'available' check (
    lifecycle_status in ('uploading', 'available', 'superseded', 'quarantined', 'deleted')
  ),
  add column storage_bucket text,
  add column storage_path text,
  add column supersedes_artifact_id uuid references public.artifacts(id) on delete set null,
  add column verified_at timestamptz;

create unique index artifacts_workspace_version_idx
  on public.artifacts (workspace_id, work_item_id, name, artifact_version)
  where work_item_id is not null and name is not null;

create or replace function control_plane_private.validate_worker_environment_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  target_organization_id uuid;
  target_venture_id uuid;
begin
  select w.organization_id, w.venture_id
    into target_organization_id, target_venture_id
  from public.workspaces w
  where w.id = new.workspace_id;

  if target_organization_id is null
     or target_organization_id <> new.organization_id
     or target_venture_id is distinct from new.venture_id then
    raise exception 'worker environment scope must match its workspace';
  end if;
  return new;
end;
$$;

create trigger worker_environments_validate_scope
before insert or update of organization_id, venture_id, workspace_id
on public.worker_environments
for each row execute function control_plane_private.validate_worker_environment_scope();

create or replace function control_plane_private.inherit_work_trace()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  parent_trace_id uuid;
begin
  if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id then
    raise exception 'work item parent is immutable';
  end if;

  if new.parent_id is not null then
    select w.trace_id into parent_trace_id
    from public.work_items w
    where w.workspace_id = new.workspace_id and w.id = new.parent_id;

    if parent_trace_id is null then
      raise exception 'parent work item does not exist in this workspace';
    end if;
    new.trace_id := parent_trace_id;
  end if;
  return new;
end;
$$;

create trigger work_items_inherit_trace
before insert or update of parent_id on public.work_items
for each row execute function control_plane_private.inherit_work_trace();

create or replace function control_plane_private.enqueue_work_signal()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.assigned_to is null or new.status <> 'queued' then
    return new;
  end if;

  insert into public.dispatch_signals (
    workspace_id, environment_id, runtime_binding_id, agent_id,
    work_item_id, idempotency_key, payload
  )
  select
    b.workspace_id, b.environment_id, b.id, b.agent_id, new.id,
    'work:' || new.id::text || ':retry:' || new.retry_count::text ||
      ':binding:' || b.id::text,
    jsonb_build_object('trace_id', new.trace_id, 'queue', new.queue)
  from public.agent_runtime_bindings b
  where b.workspace_id = new.workspace_id
    and b.agent_id = new.assigned_to
    and b.status in ('online', 'degraded')
  on conflict (workspace_id, idempotency_key) do nothing;
  return new;
end;
$$;

create trigger work_items_enqueue_signal
after insert or update of assigned_to, status, available_at on public.work_items
for each row execute function control_plane_private.enqueue_work_signal();

create or replace function public.heartbeat_agent_runtime(
  p_agent_id uuid,
  p_environment_id uuid,
  p_runtime_instance_id uuid,
  p_runtime_version text default null,
  p_routine_triggered boolean default false,
  p_metadata jsonb default '{}'::jsonb
)
returns setof public.agent_runtime_bindings
language plpgsql
security invoker
set search_path = ''
as $$
declare
  agent_workspace_id uuid;
  binding public.agent_runtime_bindings;
begin
  select a.workspace_id into agent_workspace_id
  from public.agents a
  where a.id = p_agent_id and a.status <> 'disabled';

  if agent_workspace_id is null or not exists (
    select 1 from public.worker_environments e
    where e.workspace_id = agent_workspace_id
      and e.id = p_environment_id
      and e.status in ('active', 'draining')
  ) then
    raise exception 'runtime environment is unavailable to this agent';
  end if;

  insert into public.agent_runtime_bindings (
    workspace_id, agent_id, environment_id, runtime_instance_id,
    runtime_version, status, last_seen_at, last_poll_at,
    last_routine_trigger_at, missed_poll_count, last_error, metadata
  ) values (
    agent_workspace_id, p_agent_id, p_environment_id, p_runtime_instance_id,
    nullif(trim(p_runtime_version), ''), 'online', now(), now(),
    case when p_routine_triggered then now() else null end,
    0, null, coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (agent_id, environment_id, runtime_instance_id) do update
    set runtime_version = coalesce(excluded.runtime_version, public.agent_runtime_bindings.runtime_version),
        status = 'online',
        last_seen_at = now(),
        last_poll_at = now(),
        last_routine_trigger_at = case
          when p_routine_triggered then now()
          else public.agent_runtime_bindings.last_routine_trigger_at
        end,
        missed_poll_count = 0,
        last_error = null,
        metadata = public.agent_runtime_bindings.metadata || excluded.metadata,
        updated_at = now()
  returning * into binding;

  insert into public.dispatch_signals (
    workspace_id, environment_id, runtime_binding_id, agent_id,
    work_item_id, idempotency_key, payload
  )
  select
    binding.workspace_id, binding.environment_id, binding.id,
    binding.agent_id, w.id,
    'work:' || w.id::text || ':retry:' || w.retry_count::text ||
      ':binding:' || binding.id::text,
    jsonb_build_object('trace_id', w.trace_id, 'queue', w.queue)
  from public.work_items w
  where w.workspace_id = binding.workspace_id
    and w.assigned_to = binding.agent_id
    and w.status = 'queued'
    and w.available_at <= now()
  on conflict (workspace_id, idempotency_key) do nothing;

  return next binding;
end;
$$;

create or replace function public.acknowledge_dispatch_signal(
  p_signal_id bigint,
  p_agent_id uuid
)
returns setof public.dispatch_signals
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return query
  update public.dispatch_signals s
  set status = 'acknowledged', acknowledged_at = now(), updated_at = now()
  where s.id = p_signal_id
    and s.agent_id = p_agent_id
    and s.status in ('pending', 'delivered')
  returning s.*;

  if not found then
    raise exception 'dispatch signal is unavailable to this agent';
  end if;
end;
$$;

create or replace function public.pull_dispatch_signals(
  p_runtime_binding_id uuid,
  p_agent_id uuid,
  p_limit integer default 20
)
returns setof public.dispatch_signals
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_limit < 1 or p_limit > 100 then
    raise exception 'dispatch signal limit must be between 1 and 100';
  end if;

  return query
  with selected as (
    select s.id
    from public.dispatch_signals s
    where s.runtime_binding_id = p_runtime_binding_id
      and s.agent_id = p_agent_id
      and s.status in ('pending', 'delivered')
      and s.available_at <= now()
      and (s.expires_at is null or s.expires_at > now())
    order by s.available_at, s.id
    for update skip locked
    limit p_limit
  )
  update public.dispatch_signals s
  set status = 'delivered',
      delivered_at = coalesce(s.delivered_at, now()),
      available_at = now() + interval '5 minutes',
      delivery_attempts = s.delivery_attempts + 1,
      updated_at = now()
  from selected
  where s.id = selected.id
  returning s.*;
end;
$$;

create or replace function public.run_worker_watchdog()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  degraded_count integer;
  offline_count integer;
  expired_signal_count integer;
  recovered_work_count integer;
begin
  update public.agent_runtime_bindings b
  set status = 'offline',
      missed_poll_count = greatest(
        b.missed_poll_count,
        floor(extract(epoch from (now() - b.last_seen_at)) /
          e.expected_poll_interval_seconds)::integer
      ),
      updated_at = now()
  from public.worker_environments e
  where e.workspace_id = b.workspace_id and e.id = b.environment_id
    and b.status in ('online', 'degraded')
    and b.last_seen_at < now() - make_interval(
      secs => e.expected_poll_interval_seconds * e.missed_poll_threshold * 2
    );
  get diagnostics offline_count = row_count;

  update public.agent_runtime_bindings b
  set status = 'degraded',
      missed_poll_count = greatest(
        b.missed_poll_count,
        floor(extract(epoch from (now() - b.last_seen_at)) /
          e.expected_poll_interval_seconds)::integer
      ),
      updated_at = now()
  from public.worker_environments e
  where e.workspace_id = b.workspace_id and e.id = b.environment_id
    and b.status = 'online'
    and b.last_seen_at < now() - make_interval(
      secs => e.expected_poll_interval_seconds * e.missed_poll_threshold
    );
  get diagnostics degraded_count = row_count;

  update public.dispatch_signals
  set status = 'expired', updated_at = now()
  where status in ('pending', 'delivered')
    and expires_at is not null and expires_at <= now();
  get diagnostics expired_signal_count = row_count;

  recovered_work_count := public.requeue_expired_work_items();
  return jsonb_build_object(
    'degraded_bindings', degraded_count,
    'offline_bindings', offline_count,
    'expired_signals', expired_signal_count,
    'recovered_work_items', recovered_work_count,
    'checked_at', now()
  );
end;
$$;

create trigger worker_environments_set_updated_at
before update on public.worker_environments
for each row execute function control_plane_private.set_updated_at();
create trigger agent_runtime_bindings_set_updated_at
before update on public.agent_runtime_bindings
for each row execute function control_plane_private.set_updated_at();
create trigger dispatch_signals_set_updated_at
before update on public.dispatch_signals
for each row execute function control_plane_private.set_updated_at();

alter table public.worker_environments enable row level security;
alter table public.agent_runtime_bindings enable row level security;
alter table public.dispatch_signals enable row level security;
alter table public.worker_environments force row level security;
alter table public.agent_runtime_bindings force row level security;
alter table public.dispatch_signals force row level security;

create policy worker_environments_deny_direct_access
on public.worker_environments for all to anon, authenticated
using (false) with check (false);
create policy agent_runtime_bindings_deny_direct_access
on public.agent_runtime_bindings for all to anon, authenticated
using (false) with check (false);
create policy dispatch_signals_deny_direct_access
on public.dispatch_signals for all to anon, authenticated
using (false) with check (false);

revoke all on table public.worker_environments from public, anon, authenticated;
revoke all on table public.agent_runtime_bindings from public, anon, authenticated;
revoke all on table public.dispatch_signals from public, anon, authenticated;
grant select, insert, update, delete on table public.worker_environments to service_role;
grant select, insert, update, delete on table public.agent_runtime_bindings to service_role;
grant select, insert, update, delete on table public.dispatch_signals to service_role;
grant usage, select on sequence public.dispatch_signals_id_seq to service_role;

revoke all on function public.heartbeat_agent_runtime(
  uuid, uuid, uuid, text, boolean, jsonb
) from public, anon, authenticated;
revoke all on function public.acknowledge_dispatch_signal(bigint, uuid)
  from public, anon, authenticated;
revoke all on function public.pull_dispatch_signals(uuid, uuid, integer)
  from public, anon, authenticated;
revoke all on function public.run_worker_watchdog()
  from public, anon, authenticated;
grant execute on function public.heartbeat_agent_runtime(
  uuid, uuid, uuid, text, boolean, jsonb
) to service_role;
grant execute on function public.acknowledge_dispatch_signal(bigint, uuid)
  to service_role;
grant execute on function public.pull_dispatch_signals(uuid, uuid, integer)
  to service_role;
grant execute on function public.run_worker_watchdog() to service_role;

select cron.schedule(
  'ventureos-worker-watchdog',
  '* * * * *',
  'select public.run_worker_watchdog();'
)
where not exists (
  select 1 from cron.job where jobname = 'ventureos-worker-watchdog'
);

commit;

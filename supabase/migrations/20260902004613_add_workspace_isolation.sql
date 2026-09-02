begin;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null check (length(trim(name)) between 1 and 160),
  status text not null default 'active'
    check (status in ('active', 'suspended', 'archived')),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations(id) on delete cascade,
  slug text not null
    check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null check (length(trim(name)) between 1 and 160),
  kind text not null
    check (kind in ('business', 'personal', 'client', 'internal')),
  purpose text,
  status text not null default 'active'
    check (status in ('active', 'paused', 'archived')),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, slug)
);

create index workspaces_organization_status_idx
  on public.workspaces (organization_id, status, created_at);

create trigger organizations_set_updated_at
before update on public.organizations
for each row execute function control_plane_private.set_updated_at();

create trigger workspaces_set_updated_at
before update on public.workspaces
for each row execute function control_plane_private.set_updated_at();

-- Tenant-owned rows are workspace-scoped. Registry and control records may be
-- global when workspace_id is null.
alter table public.agents
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.agent_credentials
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.work_items
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.messages
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.shared_state
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.artifacts
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.approvals
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.audit_events
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.work_attempts
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.action_outbox
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.usage_ledger
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;
alter table public.eval_results
  add column workspace_id uuid not null
    references public.workspaces(id) on delete restrict;

alter table public.policy_versions
  add column workspace_id uuid
    references public.workspaces(id) on delete cascade;
alter table public.tool_versions
  add column workspace_id uuid
    references public.workspaces(id) on delete cascade;
alter table public.budgets
  add column workspace_id uuid
    references public.workspaces(id) on delete cascade;

alter table public.control_flags
  add column id uuid default gen_random_uuid(),
  add column workspace_id uuid
    references public.workspaces(id) on delete cascade;
alter table public.control_flags alter column id set not null;

-- Identity, idempotency, and state keys are unique within a workspace rather
-- than across the entire platform.
alter table public.agents drop constraint if exists agents_name_key;
alter table public.agents
  add constraint agents_workspace_name_key unique (workspace_id, name),
  add constraint agents_workspace_id_id_key unique (workspace_id, id);

alter table public.agent_credentials
  add constraint agent_credentials_workspace_agent_fkey
  foreign key (workspace_id, agent_id)
  references public.agents(workspace_id, id);

alter table public.work_items
  drop constraint if exists work_items_idempotency_key_key;
alter table public.work_items
  add constraint work_items_workspace_id_id_key unique (workspace_id, id),
  add constraint work_items_workspace_requester_fkey
    foreign key (workspace_id, requested_by)
    references public.agents(workspace_id, id),
  add constraint work_items_workspace_assignee_fkey
    foreign key (workspace_id, assigned_to)
    references public.agents(workspace_id, id),
  add constraint work_items_workspace_parent_fkey
    foreign key (workspace_id, parent_id)
    references public.work_items(workspace_id, id);
create unique index work_items_workspace_idempotency_idx
  on public.work_items (workspace_id, idempotency_key)
  where idempotency_key is not null;

alter table public.messages
  add constraint messages_workspace_sender_fkey
    foreign key (workspace_id, from_agent)
    references public.agents(workspace_id, id),
  add constraint messages_workspace_recipient_fkey
    foreign key (workspace_id, to_agent)
    references public.agents(workspace_id, id),
  add constraint messages_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id);

alter table public.shared_state drop constraint if exists shared_state_pkey;
alter table public.shared_state
  add constraint shared_state_pkey
    primary key (workspace_id, namespace, key),
  add constraint shared_state_workspace_updater_fkey
    foreign key (workspace_id, updated_by)
    references public.agents(workspace_id, id);

alter table public.artifacts
  add constraint artifacts_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint artifacts_workspace_creator_fkey
    foreign key (workspace_id, created_by)
    references public.agents(workspace_id, id);

alter table public.approvals
  add constraint approvals_workspace_id_id_key unique (workspace_id, id),
  add constraint approvals_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint approvals_workspace_requester_fkey
    foreign key (workspace_id, requested_by)
    references public.agents(workspace_id, id);

alter table public.work_attempts
  add constraint work_attempts_workspace_id_id_key unique (workspace_id, id),
  add constraint work_attempts_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint work_attempts_workspace_agent_fkey
    foreign key (workspace_id, agent_id)
    references public.agents(workspace_id, id);

alter table public.action_outbox
  drop constraint if exists action_outbox_idempotency_key_key;
alter table public.action_outbox
  add constraint action_outbox_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint action_outbox_workspace_attempt_fkey
    foreign key (workspace_id, attempt_id)
    references public.work_attempts(workspace_id, id),
  add constraint action_outbox_workspace_requester_fkey
    foreign key (workspace_id, requested_by)
    references public.agents(workspace_id, id),
  add constraint action_outbox_workspace_approval_fkey
    foreign key (workspace_id, approval_id)
    references public.approvals(workspace_id, id);
create unique index action_outbox_workspace_idempotency_idx
  on public.action_outbox (workspace_id, idempotency_key);

alter table public.audit_events
  add constraint audit_events_workspace_agent_fkey
    foreign key (workspace_id, agent_id)
    references public.agents(workspace_id, id),
  add constraint audit_events_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint audit_events_workspace_attempt_fkey
    foreign key (workspace_id, attempt_id)
    references public.work_attempts(workspace_id, id);

alter table public.usage_ledger
  add constraint usage_ledger_workspace_agent_fkey
    foreign key (workspace_id, agent_id)
    references public.agents(workspace_id, id),
  add constraint usage_ledger_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint usage_ledger_workspace_attempt_fkey
    foreign key (workspace_id, attempt_id)
    references public.work_attempts(workspace_id, id);

alter table public.eval_results
  add constraint eval_results_workspace_work_item_fkey
    foreign key (workspace_id, work_item_id)
    references public.work_items(workspace_id, id),
  add constraint eval_results_workspace_attempt_fkey
    foreign key (workspace_id, attempt_id)
    references public.work_attempts(workspace_id, id);

-- Replace global uniqueness with global-or-workspace uniqueness.
drop index if exists public.one_pending_approval_per_action;
create unique index one_pending_approval_per_action
  on public.approvals (workspace_id, work_item_id, action_type)
  where status = 'pending';

alter table public.policy_versions
  drop constraint if exists policy_versions_policy_name_version_key;
drop index if exists public.one_active_policy_version;
create unique index policy_versions_scope_name_version_idx
  on public.policy_versions (
    coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid),
    policy_name,
    version
  );
create unique index one_active_policy_version
  on public.policy_versions (
    coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid),
    policy_name
  )
  where is_active;

alter table public.tool_versions
  drop constraint if exists tool_versions_tool_name_version_key;
create unique index tool_versions_scope_name_version_idx
  on public.tool_versions (
    coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid),
    tool_name,
    version
  );

alter table public.control_flags drop constraint if exists control_flags_pkey;
alter table public.control_flags
  add constraint control_flags_pkey primary key (id),
  add constraint control_flags_scope_check check (
    (scope = 'global' and workspace_id is null)
    or (scope = 'workspace' and workspace_id is not null)
  );
create unique index control_flags_scope_key_idx
  on public.control_flags (
    coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid),
    scope,
    key
  );

alter table public.budgets
  drop constraint if exists budgets_scope_type_check,
  drop constraint if exists budgets_scope_type_scope_id_period_start_period_end_key;
alter table public.budgets
  add constraint budgets_scope_type_check check (
    scope_type in ('global', 'workspace', 'agent', 'workflow', 'customer')
  ),
  add constraint budgets_workspace_scope_check check (
    (scope_type = 'global' and workspace_id is null)
    or (scope_type <> 'global' and workspace_id is not null)
  );
create unique index budgets_scope_period_idx
  on public.budgets (
    coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid),
    scope_type,
    scope_id,
    period_start,
    period_end
  );

-- Workspace-leading indexes match the gateway's filter and queue patterns.
drop index if exists public.agent_credentials_agent_idx;
create index agent_credentials_workspace_agent_idx
  on public.agent_credentials (workspace_id, agent_id);
create index agents_workspace_status_idx
  on public.agents (workspace_id, status, created_at);

drop index if exists public.work_items_claim_idx;
drop index if exists public.work_items_queue_claim_idx;
drop index if exists public.work_items_assignee_idx;
drop index if exists public.work_items_requester_idx;
drop index if exists public.work_items_parent_idx;
create index work_items_workspace_queue_claim_idx
  on public.work_items (
    workspace_id, queue, priority desc, available_at, created_at
  ) where status = 'queued';
create index work_items_workspace_assignee_idx
  on public.work_items (workspace_id, assigned_to, status);
create index work_items_workspace_requester_idx
  on public.work_items (workspace_id, requested_by, created_at)
  where requested_by is not null;
create index work_items_workspace_parent_idx
  on public.work_items (workspace_id, parent_id)
  where parent_id is not null;

drop index if exists public.messages_inbox_idx;
drop index if exists public.messages_sender_idx;
drop index if exists public.messages_work_item_idx;
create index messages_workspace_inbox_idx
  on public.messages (workspace_id, to_agent, read_at, created_at);
create index messages_workspace_sender_idx
  on public.messages (workspace_id, from_agent, created_at)
  where from_agent is not null;
create index messages_workspace_work_item_idx
  on public.messages (workspace_id, work_item_id, created_at)
  where work_item_id is not null;

create index artifacts_workspace_created_idx
  on public.artifacts (workspace_id, created_at);
create index approvals_workspace_created_idx
  on public.approvals (workspace_id, created_at);
create index audit_events_workspace_created_idx
  on public.audit_events (workspace_id, created_at);
create index work_attempts_workspace_active_idx
  on public.work_attempts (workspace_id, agent_id, heartbeat_at)
  where status = 'started';
create index action_outbox_workspace_delivery_idx
  on public.action_outbox (workspace_id, next_attempt_at, created_at)
  where status in ('ready', 'failed');
create index usage_ledger_workspace_created_idx
  on public.usage_ledger (workspace_id, created_at);
create index eval_results_workspace_created_idx
  on public.eval_results (workspace_id, created_at);
create index policy_versions_workspace_idx
  on public.policy_versions (workspace_id, policy_name);
create index tool_versions_workspace_idx
  on public.tool_versions (workspace_id, tool_name);
create index budgets_workspace_period_idx
  on public.budgets (workspace_id, period_start, period_end);

-- Workspace ownership is immutable after creation. Moving a record between
-- workspaces would bypass audit history and idempotency boundaries.
create or replace function control_plane_private.prevent_workspace_reassignment()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.workspace_id is distinct from old.workspace_id then
    raise exception 'workspace assignment is immutable';
  end if;
  return new;
end;
$$;

create or replace function control_plane_private.prevent_organization_reassignment()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'workspace organization is immutable';
  end if;
  return new;
end;
$$;

create trigger workspaces_prevent_organization_reassignment
before update on public.workspaces
for each row execute function control_plane_private.prevent_organization_reassignment();

create trigger agents_prevent_workspace_reassignment
before update on public.agents
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger agent_credentials_prevent_workspace_reassignment
before update on public.agent_credentials
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger work_items_prevent_workspace_reassignment
before update on public.work_items
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger messages_prevent_workspace_reassignment
before update on public.messages
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger shared_state_prevent_workspace_reassignment
before update on public.shared_state
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger artifacts_prevent_workspace_reassignment
before update on public.artifacts
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger approvals_prevent_workspace_reassignment
before update on public.approvals
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger work_attempts_prevent_workspace_reassignment
before update on public.work_attempts
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger action_outbox_prevent_workspace_reassignment
before update on public.action_outbox
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger budgets_prevent_workspace_reassignment
before update on public.budgets
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger eval_results_prevent_workspace_reassignment
before update on public.eval_results
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger policy_versions_prevent_workspace_reassignment
before update on public.policy_versions
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger tool_versions_prevent_workspace_reassignment
before update on public.tool_versions
for each row execute function control_plane_private.prevent_workspace_reassignment();
create trigger control_flags_prevent_workspace_reassignment
before update on public.control_flags
for each row execute function control_plane_private.prevent_workspace_reassignment();

-- Approval and outbox identity now includes the workspace boundary.
create or replace function control_plane_private.protect_approval_payload()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.payload_sha256 = encode(
      extensions.digest(convert_to(new.payload::text, 'UTF8'), 'sha256'),
      'hex'
    );
    return new;
  end if;

  if new.workspace_id is distinct from old.workspace_id
     or new.work_item_id is distinct from old.work_item_id
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

create or replace function control_plane_private.validate_outbox_action()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  approval_record public.approvals;
  calculated_hash text;
begin
  calculated_hash := encode(
    extensions.digest(convert_to(new.payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  if tg_op = 'UPDATE' and (
       new.workspace_id is distinct from old.workspace_id
       or new.work_item_id is distinct from old.work_item_id
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
    where key = 'outbound_actions_disabled'
      and enabled
      and (
        (scope = 'global' and workspace_id is null)
        or (scope = 'workspace' and workspace_id = new.workspace_id)
      )
  ) then
    raise exception 'outbound actions are disabled by control flag';
  end if;

  if new.requires_approval and new.status in ('ready', 'delivering', 'delivered') then
    if new.approval_id is null then
      raise exception 'approval is required before action delivery';
    end if;

    select * into approval_record
    from public.approvals
    where id = new.approval_id
      and workspace_id = new.workspace_id;

    if not found then
      raise exception 'approval does not exist in this workspace';
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
    if approval_record.expires_at is not null
       and approval_record.expires_at <= now() then
      raise exception 'approval has expired';
    end if;
  end if;

  return new;
end;
$$;

-- Replace unscoped operational functions. Old signatures are removed so a
-- future caller cannot accidentally bypass workspace isolation.
drop function public.register_agent(
  uuid, text, text, text, smallint, text[], smallint, text, timestamptz, jsonb
);

create function public.register_agent(
  p_workspace_id uuid,
  p_credential_id uuid,
  p_key_hash text,
  p_name text,
  p_role text,
  p_authority_level smallint default 1,
  p_capabilities text[] default '{}',
  p_max_concurrency smallint default 1,
  p_credential_label text default 'primary',
  p_expires_at timestamptz default null,
  p_metadata jsonb default '{}'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  created_agent public.agents;
  created_organization_id uuid;
begin
  select w.organization_id
  into created_organization_id
    from public.workspaces w
    join public.organizations o on o.id = w.organization_id
    where w.id = p_workspace_id
      and w.status = 'active'
      and o.status = 'active'
  ;

  if created_organization_id is null then
    raise exception 'workspace is unavailable';
  end if;
  if length(trim(p_name)) = 0 or length(trim(p_role)) = 0 then
    raise exception 'agent name and role are required';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'credential expiration must be in the future';
  end if;

  insert into public.agents (
    workspace_id, name, role, authority_level, capabilities, status,
    max_concurrency, metadata, last_seen_at
  ) values (
    p_workspace_id, p_name, p_role, p_authority_level, p_capabilities, 'idle',
    p_max_concurrency, p_metadata, now()
  ) returning * into created_agent;

  insert into public.agent_credentials (
    workspace_id, id, agent_id, label, key_hash, expires_at
  ) values (
    p_workspace_id, p_credential_id, created_agent.id,
    p_credential_label, p_key_hash, p_expires_at
  );

  insert into public.audit_events (
    workspace_id, agent_id, event_type, payload
  ) values (
    p_workspace_id,
    created_agent.id,
    'registered',
    jsonb_build_object('credential_id', p_credential_id, 'label', p_credential_label)
  );

  return jsonb_build_object(
    'agent', to_jsonb(created_agent) || jsonb_build_object(
      'organization_id', created_organization_id
    ),
    'credential_id', p_credential_id
  );
end;
$$;

drop function public.compare_and_swap_shared_state(
  text, text, jsonb, bigint, uuid
);

create function public.compare_and_swap_shared_state(
  p_workspace_id uuid,
  p_namespace text,
  p_key text,
  p_value jsonb,
  p_expected_version bigint,
  p_updated_by uuid default null
)
returns public.shared_state
language plpgsql
security invoker
set search_path = ''
as $$
declare
  saved public.shared_state;
begin
  if p_expected_version < 0 then
    raise exception 'expected version must be zero or greater';
  end if;
  if p_updated_by is not null and not exists (
    select 1 from public.agents
    where id = p_updated_by and workspace_id = p_workspace_id
  ) then
    raise exception 'state updater is not in this workspace';
  end if;

  if p_expected_version = 0 then
    insert into public.shared_state (
      workspace_id, namespace, key, value, updated_by
    ) values (
      p_workspace_id, p_namespace, p_key, p_value, p_updated_by
    )
    on conflict (workspace_id, namespace, key) do nothing
    returning * into saved;
  else
    update public.shared_state
    set value = p_value,
        version = version + 1,
        updated_by = p_updated_by,
        updated_at = now()
    where workspace_id = p_workspace_id
      and namespace = p_namespace
      and key = p_key
      and version = p_expected_version
    returning * into saved;
  end if;

  if saved.workspace_id is null then
    raise exception 'shared state version conflict';
  end if;

  insert into public.audit_events (
    workspace_id, agent_id, event_type, payload
  ) values (
    p_workspace_id,
    p_updated_by,
    'shared_state_updated',
    jsonb_build_object(
      'namespace', p_namespace, 'key', p_key, 'version', saved.version
    )
  );

  return saved;
end;
$$;

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
  new_lease_token uuid := gen_random_uuid();
  new_attempt_number integer;
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
  if not exists (
    select 1
    from public.workspaces w
    join public.organizations o on o.id = w.organization_id
    where w.id = claiming_agent.workspace_id
      and w.status = 'active'
      and o.status = 'active'
  ) then
    return null;
  end if;

  select count(*) into active_count
  from public.work_items
  where workspace_id = claiming_agent.workspace_id
    and assigned_to = p_agent_id
    and status in ('claimed', 'running', 'waiting_approval');

  if active_count >= claiming_agent.max_concurrency then
    return null;
  end if;

  if exists (
    select 1 from public.control_flags
    where key = 'work_claims_paused'
      and enabled
      and (
        (scope = 'global' and workspace_id is null)
        or (
          scope = 'workspace'
          and workspace_id = claiming_agent.workspace_id
        )
      )
  ) then
    return null;
  end if;

  select w.* into claimed
  from public.work_items w
  where w.workspace_id = claiming_agent.workspace_id
    and w.status = 'queued'
    and w.available_at <= now()
    and (w.assigned_to is null or w.assigned_to = p_agent_id)
    and w.required_capabilities <@ claiming_agent.capabilities
  order by w.priority desc, w.created_at
  for update skip locked
  limit 1;

  if claimed.id is null then
    return null;
  end if;

  select coalesce(max(attempt_number), 0) + 1 into new_attempt_number
  from public.work_attempts
  where workspace_id = claiming_agent.workspace_id
    and work_item_id = claimed.id;

  update public.work_items
  set status = 'claimed',
      assigned_to = p_agent_id,
      claimed_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      lease_token = new_lease_token,
      lease_version = lease_version + 1
  where workspace_id = claiming_agent.workspace_id
    and id = claimed.id
  returning * into claimed;

  insert into public.work_attempts (
    workspace_id, work_item_id, attempt_number, agent_id, trace_id,
    lease_token, lease_version, prompt_version, toolset_version,
    policy_version, input_snapshot
  ) values (
    claiming_agent.workspace_id, claimed.id, new_attempt_number, p_agent_id,
    claimed.trace_id, claimed.lease_token, claimed.lease_version,
    claimed.prompt_version, claimed.toolset_version, claimed.policy_version,
    claimed.input
  );

  insert into public.audit_events (
    workspace_id, agent_id, work_item_id, trace_id, event_type,
    policy_version, prompt_version
  ) values (
    claiming_agent.workspace_id, p_agent_id, claimed.id, claimed.trace_id,
    'claimed', claimed.policy_version, claimed.prompt_version
  );

  update public.agents
  set status = 'busy', last_seen_at = now()
  where workspace_id = claiming_agent.workspace_id
    and id = p_agent_id;

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
      when item.retry_count + 1 > item.max_retries
        then 'dead_letter'::public.work_status
      else 'queued'::public.work_status
    end;
    retry_delay_seconds := least(
      900,
      (power(2, item.retry_count)::integer * 5)
    );

    update public.work_attempts
    set status = 'timed_out', ended_at = now(),
        error = jsonb_build_object('type', 'lease_expired')
    where workspace_id = item.workspace_id
      and work_item_id = item.id
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
    where workspace_id = item.workspace_id and id = item.id;

    update public.agents
    set status = case
          when exists (
            select 1 from public.work_items
            where workspace_id = item.workspace_id
              and assigned_to = item.assigned_to
              and status in ('claimed', 'running', 'waiting_approval')
          ) then 'busy'::public.agent_status
          else 'idle'::public.agent_status
        end
    where workspace_id = item.workspace_id and id = item.assigned_to;

    insert into public.audit_events (
      workspace_id, agent_id, work_item_id, trace_id, event_type, payload
    ) values (
      item.workspace_id, item.assigned_to, item.id, item.trace_id,
      'lease_expired',
      jsonb_build_object(
        'next_status', next_status,
        'retry_delay_seconds', retry_delay_seconds
      )
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
security invoker
set search_path = ''
as $$
declare
  agent_workspace_id uuid;
  new_expiration timestamptz;
begin
  if p_extend_seconds < 30 or p_extend_seconds > 900 then
    raise exception 'heartbeat extension must be between 30 and 900 seconds';
  end if;
  select workspace_id into agent_workspace_id
  from public.agents where id = p_agent_id;
  if agent_workspace_id is null then
    raise exception 'agent does not exist';
  end if;

  update public.work_items
  set lease_expires_at = greatest(lease_expires_at, now())
    + make_interval(secs => p_extend_seconds)
  where workspace_id = agent_workspace_id
    and id = p_work_item_id
    and assigned_to = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status in ('claimed', 'running')
    and cancellation_requested_at is null
  returning lease_expires_at into new_expiration;

  if new_expiration is null then
    raise exception 'stale, cancelled, invalid, or cross-workspace work lease';
  end if;

  update public.work_attempts
  set heartbeat_at = now()
  where workspace_id = agent_workspace_id
    and work_item_id = p_work_item_id
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
security invoker
set search_path = ''
as $$
declare
  agent_workspace_id uuid;
  completed public.work_items;
  active_attempt_id uuid;
begin
  select workspace_id into agent_workspace_id
  from public.agents where id = p_agent_id;
  if agent_workspace_id is null then
    raise exception 'agent does not exist';
  end if;

  select id into active_attempt_id
  from public.work_attempts
  where workspace_id = agent_workspace_id
    and work_item_id = p_work_item_id
    and agent_id = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status = 'started'
  for update;

  if active_attempt_id is null then
    raise exception 'stale, invalid, or cross-workspace work attempt';
  end if;

  update public.work_items
  set status = 'completed',
      output = p_output,
      completed_at = now(),
      lease_expires_at = null,
      lease_token = null
  where workspace_id = agent_workspace_id
    and id = p_work_item_id
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
  where workspace_id = agent_workspace_id and id = active_attempt_id;

  update public.agents
  set status = case
        when exists (
          select 1 from public.work_items
          where workspace_id = agent_workspace_id
            and assigned_to = p_agent_id
            and status in ('claimed', 'running', 'waiting_approval')
        ) then 'busy'::public.agent_status
        else 'idle'::public.agent_status
      end,
      last_seen_at = now()
  where workspace_id = agent_workspace_id and id = p_agent_id;

  insert into public.audit_events (
    workspace_id, agent_id, work_item_id, trace_id, attempt_id, event_type
  ) values (
    agent_workspace_id, p_agent_id, completed.id, completed.trace_id,
    active_attempt_id, 'completed'
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
security invoker
set search_path = ''
as $$
declare
  agent_workspace_id uuid;
  failed public.work_items;
  active_attempt_id uuid;
  next_status public.work_status;
  retry_delay_seconds integer;
begin
  select workspace_id into agent_workspace_id
  from public.agents where id = p_agent_id;
  if agent_workspace_id is null then
    raise exception 'agent does not exist';
  end if;

  select id into active_attempt_id
  from public.work_attempts
  where workspace_id = agent_workspace_id
    and work_item_id = p_work_item_id
    and agent_id = p_agent_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and status = 'started'
  for update;

  if active_attempt_id is null then
    raise exception 'stale, invalid, or cross-workspace work attempt';
  end if;

  select * into failed
  from public.work_items
  where workspace_id = agent_workspace_id and id = p_work_item_id
  for update;

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
  retry_delay_seconds := least(
    900,
    (power(2, failed.retry_count)::integer * 5)
  );

  update public.work_attempts
  set status = 'failed', error = p_error, ended_at = now()
  where workspace_id = agent_workspace_id and id = active_attempt_id;

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
        when next_status = 'queued'
          then now() + make_interval(secs => retry_delay_seconds)
        else available_at
      end
  where workspace_id = agent_workspace_id and id = p_work_item_id
  returning * into failed;

  update public.agents
  set status = case
        when exists (
          select 1 from public.work_items
          where workspace_id = agent_workspace_id
            and assigned_to = p_agent_id
            and status in ('claimed', 'running', 'waiting_approval')
        ) then 'busy'::public.agent_status
        else 'idle'::public.agent_status
      end,
      last_seen_at = now()
  where workspace_id = agent_workspace_id and id = p_agent_id;

  insert into public.audit_events (
    workspace_id, agent_id, work_item_id, trace_id, attempt_id,
    event_type, payload
  ) values (
    agent_workspace_id, p_agent_id, failed.id, failed.trace_id,
    active_attempt_id, 'failed',
    jsonb_build_object(
      'failure_class', p_failure_class,
      'retryable', p_retryable,
      'next_status', next_status
    )
  );

  return failed;
end;
$$;

drop function public.reserve_budget(
  text, text, numeric, bigint, bigint, bigint
);

create function public.reserve_budget(
  p_workspace_id uuid,
  p_scope_type text,
  p_scope_id text,
  p_cost_usd numeric,
  p_input_tokens bigint default 0,
  p_output_tokens bigint default 0,
  p_tool_calls bigint default 0
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  selected_budget public.budgets;
begin
  if p_cost_usd < 0
     or p_input_tokens < 0
     or p_output_tokens < 0
     or p_tool_calls < 0 then
    raise exception 'budget reservation values must be non-negative';
  end if;

  select * into selected_budget
  from public.budgets
  where workspace_id is not distinct from p_workspace_id
    and scope_type = p_scope_type
    and scope_id = p_scope_id
    and period_start <= now()
    and period_end > now()
  order by period_start desc
  for update
  limit 1;

  if not found then
    return false;
  end if;
  if selected_budget.spent_usd + p_cost_usd
     > selected_budget.hard_limit_usd then
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

-- New tables use the same private-by-default Data API boundary.
alter table public.organizations enable row level security;
alter table public.workspaces enable row level security;
alter table public.organizations force row level security;
alter table public.workspaces force row level security;

create policy deny_direct_agent_access on public.organizations
  for all to anon, authenticated using (false) with check (false);
create policy deny_direct_agent_access on public.workspaces
  for all to anon, authenticated using (false) with check (false);

revoke all on public.organizations from public, anon, authenticated;
revoke all on public.workspaces from public, anon, authenticated;
revoke all on function public.register_agent(
  uuid, uuid, text, text, text, smallint, text[], smallint,
  text, timestamptz, jsonb
) from public, anon, authenticated;
revoke all on function public.compare_and_swap_shared_state(
  uuid, text, text, jsonb, bigint, uuid
) from public, anon, authenticated;
revoke all on function public.reserve_budget(
  uuid, text, text, numeric, bigint, bigint, bigint
) from public, anon, authenticated;
revoke all on all functions in schema control_plane_private
  from public, anon, authenticated, service_role;

grant select, insert, update on public.organizations to service_role;
grant select, insert, update on public.workspaces to service_role;
grant execute on function public.register_agent(
  uuid, uuid, text, text, text, smallint, text[], smallint,
  text, timestamptz, jsonb
) to service_role;
grant execute on function public.compare_and_swap_shared_state(
  uuid, text, text, jsonb, bigint, uuid
) to service_role;
grant execute on function public.reserve_budget(
  uuid, text, text, numeric, bigint, bigint, bigint
) to service_role;

commit;

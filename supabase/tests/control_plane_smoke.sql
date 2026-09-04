-- Run after all control-plane migrations. Every fixture is rolled back.
begin;

do $$
declare
  unsafe_tables integer;
  unsafe_functions integer;
begin
  select count(*) into unsafe_tables
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and c.relname in (
      'organizations', 'workspaces', 'agents', 'agent_credentials',
      'work_items', 'messages', 'shared_state', 'artifacts', 'approvals',
      'audit_events', 'work_attempts', 'policy_versions', 'tool_versions',
      'action_outbox', 'control_flags', 'budgets', 'usage_ledger',
      'eval_results', 'ventures', 'agent_workspace_memberships',
      'venture_blueprints', 'venture_blueprint_versions',
      'venture_blueprint_instances', 'brand_profiles', 'model_providers',
      'model_deployments', 'task_profiles', 'model_routing_policies',
      'model_routing_decisions', 'model_budget_reservations',
      'worker_environments', 'agent_runtime_bindings', 'dispatch_signals'
    )
    and (not c.relrowsecurity or not c.relforcerowsecurity);

  if unsafe_tables <> 0 then
    raise exception '% control-plane tables lack RLS or FORCE RLS', unsafe_tables;
  end if;

  select count(*) into unsafe_functions
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'register_agent', 'claim_next_work_item', 'requeue_expired_work_items',
      'heartbeat_work_attempt', 'complete_work_attempt', 'fail_work_attempt',
      'reserve_budget', 'compare_and_swap_shared_state',
      'reserve_model_budget', 'settle_model_budget',
      'release_expired_model_budget_reservations',
      'heartbeat_agent_runtime', 'pull_dispatch_signals',
      'acknowledge_dispatch_signal', 'run_worker_watchdog'
    )
    and p.prosecdef;

  if unsafe_functions <> 0 then
    raise exception '% operational functions use SECURITY DEFINER', unsafe_functions;
  end if;

  if has_function_privilege(
       'anon',
       'public.register_agent(uuid, uuid, text, text, text, smallint, text[], smallint, text, timestamptz, jsonb)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.claim_next_work_item(uuid, integer)',
       'EXECUTE'
     ) then
    raise exception 'operational function is executable by a public API role';
  end if;
end;
$$;

do $$
declare
  organization_id uuid;
  workspace_a uuid;
  workspace_b uuid;
  venture_a uuid;
  agent_a uuid;
  agent_b uuid;
  registration jsonb;
  work_a uuid;
  work_a_second uuid;
  claimed public.work_items;
  forbidden_claim public.work_items;
  saved public.shared_state;
  approval_id uuid;
  cross_message_blocked boolean := false;
  reassignment_blocked boolean := false;
  state_conflict_blocked boolean := false;
  approval_tamper_blocked boolean := false;
  outbound_blocked boolean := false;
  first_reservation boolean;
  second_reservation boolean;
begin
  insert into public.organizations (slug, name)
  values ('smoke-' || gen_random_uuid()::text, 'Smoke Organization')
  returning id into organization_id;

  insert into public.ventures (
    organization_id, slug, name, venture_type, stage
  ) values (
    organization_id, 'venture-a', 'Venture A', 'proof_of_concept', 'validation'
  ) returning id into venture_a;

  insert into public.workspaces (
    organization_id, venture_id, slug, name, kind, purpose
  ) values (
    organization_id, venture_a, 'business-a', 'Business A', 'business',
    'isolation smoke test'
  ) returning id into workspace_a;

  insert into public.workspaces (
    organization_id, slug, name, kind, purpose
  ) values (
    organization_id, 'department-b', 'Department B', 'department', 'isolation smoke test'
  ) returning id into workspace_b;

  registration := public.register_agent(
    workspace_a, gen_random_uuid(),
    'scrypt$16384$8$1$test-salt-a$test-hash-a',
    'business-agent-' || gen_random_uuid()::text, 'business smoke agent',
    2::smallint, array['research'], 1::smallint, 'smoke',
    now() + interval '1 hour', '{}'::jsonb
  );
  agent_a := (registration->'agent'->>'id')::uuid;

  if registration->'agent'->>'organization_id' <> organization_id::text
     or registration->'agent'->>'workspace_id' <> workspace_a::text then
    raise exception 'agent registration did not return its tenant scope';
  end if;

  registration := public.register_agent(
    workspace_b, gen_random_uuid(),
    'scrypt$16384$8$1$test-salt-b$test-hash-b',
    'department-agent-' || gen_random_uuid()::text, 'department smoke agent',
    1::smallint, array['research'], 1::smallint, 'smoke',
    now() + interval '1 hour', '{}'::jsonb
  );
  agent_b := (registration->'agent'->>'id')::uuid;

  if not exists (
    select 1 from public.agent_workspace_memberships
    where agent_id = agent_a and workspace_id = workspace_a and status = 'active'
  ) then
    raise exception 'new agent did not receive a home-workspace membership';
  end if;

  insert into public.work_items (
    workspace_id, requested_by, work_type, title, priority,
    required_capabilities
  ) values (
    workspace_a, agent_a, 'smoke', 'workspace A claim', 100,
    array['research']
  ) returning id into work_a;

  select * into forbidden_claim from public.claim_next_work_item(agent_b, 60);
  if forbidden_claim.id is not null then
    raise exception 'agent claimed work from another workspace';
  end if;

  select * into claimed from public.claim_next_work_item(agent_a, 60);
  if claimed.id <> work_a or claimed.workspace_id <> workspace_a then
    raise exception 'workspace-scoped claim failed';
  end if;

  perform public.complete_work_attempt(
    claimed.id, agent_a, claimed.lease_token, claimed.lease_version,
    '{"ok": true}'::jsonb
  );

  begin
    insert into public.messages (
      workspace_id, from_agent, to_agent, kind, body
    ) values (workspace_b, agent_b, agent_a, 'task', '{}'::jsonb);
  exception when foreign_key_violation then
    cross_message_blocked := true;
  end;
  if not cross_message_blocked then
    raise exception 'cross-workspace message was accepted';
  end if;

  select * into saved from public.compare_and_swap_shared_state(
    workspace_a, 'smoke', 'same-key', '{"workspace": "a"}'::jsonb, 0, agent_a
  );
  perform public.compare_and_swap_shared_state(
    workspace_b, 'smoke', 'same-key', '{"workspace": "b"}'::jsonb, 0, agent_b
  );
  if saved.version <> 1
     or (select value->>'workspace' from public.shared_state
         where workspace_id = workspace_a and namespace = 'smoke' and key = 'same-key') <> 'a'
     or (select value->>'workspace' from public.shared_state
         where workspace_id = workspace_b and namespace = 'smoke' and key = 'same-key') <> 'b' then
    raise exception 'workspace state isolation failed';
  end if;

  begin
    perform public.compare_and_swap_shared_state(
      workspace_a, 'smoke', 'same-key', '{"workspace": "stale"}'::jsonb, 0, agent_a
    );
  exception when others then
    state_conflict_blocked := true;
  end;
  if not state_conflict_blocked then
    raise exception 'stale shared-state write was accepted';
  end if;

  begin
    update public.agents set workspace_id = workspace_b where id = agent_a;
  exception when others then
    reassignment_blocked := true;
  end;
  if not reassignment_blocked then
    raise exception 'agent workspace reassignment was accepted';
  end if;

  insert into public.work_items (
    workspace_id, requested_by, work_type, title
  ) values (workspace_a, agent_a, 'smoke', 'approval and outbox')
  returning id into work_a_second;

  insert into public.approvals (
    workspace_id, work_item_id, requested_by, action_type, summary,
    payload, risk, status
  ) values (
    workspace_a, work_a_second, agent_a, 'email.send', 'smoke',
    '{"body": "approved"}'::jsonb, 'high', 'approved'
  ) returning id into approval_id;

  begin
    update public.approvals
    set payload = '{"body": "tampered"}'::jsonb
    where workspace_id = workspace_a and id = approval_id;
  exception when others then
    approval_tamper_blocked := true;
  end;
  if not approval_tamper_blocked then
    raise exception 'approved payload mutation was accepted';
  end if;

  begin
    insert into public.action_outbox (
      workspace_id, work_item_id, approval_id, requested_by,
      action_type, payload, payload_sha256, idempotency_key, status
    ) values (
      workspace_a, work_a_second, approval_id, agent_a,
      'email.send', '{"body": "approved"}'::jsonb,
      encode(extensions.digest(
        convert_to('{"body": "approved"}'::jsonb::text, 'UTF8'), 'sha256'
      ), 'hex'),
      'smoke-' || gen_random_uuid()::text, 'ready'
    );
  exception when others then
    outbound_blocked := true;
  end;
  if not outbound_blocked then
    raise exception 'outbound-action kill switch failed';
  end if;

  insert into public.budgets (
    workspace_id, scope_type, scope_id, period_start, period_end, hard_limit_usd
  ) values (
    workspace_a, 'workspace', workspace_a::text,
    now() - interval '1 minute', now() + interval '1 hour', 1.00
  );
  first_reservation := public.reserve_budget(
    workspace_a, 'workspace', workspace_a::text, 0.40
  );
  second_reservation := public.reserve_budget(
    workspace_a, 'workspace', workspace_a::text, 0.70
  );
  if not first_reservation or second_reservation then
    raise exception 'workspace hard budget cap was not enforced';
  end if;
end;
$$;

do $$
declare
  organization_a uuid;
  organization_b uuid;
  venture_a uuid;
  workspace_a uuid;
  workspace_b uuid;
  agent_a uuid;
  registration jsonb;
  blueprint_hash text;
  provider_id uuid;
  deployment_id uuid;
  profile_id uuid;
  policy_id uuid;
  decision_id uuid;
  second_decision_id uuid;
  budget_id uuid;
  reservation public.model_budget_reservations;
  settled public.model_budget_reservations;
  cross_tenant_membership_blocked boolean := false;
  cross_scope_budget_blocked boolean := false;
  hard_limit_blocked boolean := false;
begin
  insert into public.organizations (slug, name)
  values ('venture-smoke-a-' || gen_random_uuid()::text, 'Venture Smoke A')
  returning id into organization_a;
  insert into public.organizations (slug, name)
  values ('venture-smoke-b-' || gen_random_uuid()::text, 'Venture Smoke B')
  returning id into organization_b;

  insert into public.ventures (
    organization_id, slug, name, venture_type, stage
  ) values (
    organization_a, 'test-venture', 'Test Venture', 'proof_of_concept', 'validation'
  ) returning id into venture_a;

  insert into public.workspaces (
    organization_id, venture_id, slug, name, kind
  ) values (
    organization_a, venture_a, 'research', 'Research', 'department'
  ) returning id into workspace_a;
  insert into public.workspaces (
    organization_id, slug, name, kind
  ) values (
    organization_b, 'other-tenant', 'Other Tenant', 'internal'
  ) returning id into workspace_b;

  registration := public.register_agent(
    workspace_a, gen_random_uuid(),
    'scrypt$16384$8$1$venture-salt$venture-hash',
    'venture-agent-' || gen_random_uuid()::text, 'venture smoke agent',
    1::smallint, array['research'], 1::smallint, 'smoke',
    now() + interval '1 hour', '{}'::jsonb
  );
  agent_a := (registration->'agent'->>'id')::uuid;

  begin
    insert into public.agent_workspace_memberships (agent_id, workspace_id)
    values (agent_a, workspace_b);
  exception when others then
    cross_tenant_membership_blocked := true;
  end;
  if not cross_tenant_membership_blocked then
    raise exception 'cross-tenant agent membership was accepted';
  end if;

  select definition_sha256 into blueprint_hash
  from public.venture_blueprint_versions v
  join public.venture_blueprints b on b.id = v.blueprint_id
  where b.organization_id is null
    and b.slug = 'lean-b2b-service'
    and v.version = '1.0.0';
  if blueprint_hash is null or length(blueprint_hash) <> 64 then
    raise exception 'venture blueprint checksum was not generated';
  end if;

  insert into public.model_providers (slug, name, api_family)
  values ('smoke-provider', 'Smoke Provider', 'test')
  returning id into provider_id;
  insert into public.model_deployments (
    provider_id, model_key, display_name, endpoint_class, capabilities,
    input_usd_per_million, output_usd_per_million, pricing_effective_at
  ) values (
    provider_id, 'smoke-model', 'Smoke Model', 'hosted', array['research'],
    1, 2, now()
  ) returning id into deployment_id;
  insert into public.task_profiles (
    organization_id, venture_id, slug, name, required_capabilities,
    max_cost_usd
  ) values (
    organization_a, venture_a, 'evidence-research', 'Evidence Research',
    array['research'], 0.50
  ) returning id into profile_id;
  insert into public.model_routing_policies (
    task_profile_id, version, strategy, is_active
  ) values (
    profile_id, '1.0.0', 'balanced', true
  ) returning id into policy_id;
  insert into public.model_routing_decisions (
    workspace_id, task_profile_id, routing_policy_id,
    selected_model_deployment_id, candidate_snapshot,
    estimated_input_tokens, estimated_output_tokens, estimated_cost_usd,
    reason
  ) values (
    workspace_a, profile_id, policy_id, deployment_id,
    jsonb_build_array(jsonb_build_object(
      'model_deployment_id', deployment_id,
      'quality_score', 0.9,
      'estimated_cost_usd', 0.40
    )),
    1000, 1000, 0.40, 'highest eligible score within task cap'
  ) returning id into decision_id;

  insert into public.budgets (
    venture_id, scope_type, scope_id, period_start, period_end,
    hard_limit_usd, soft_limit_usd
  ) values (
    venture_a, 'venture', venture_a::text,
    now() - interval '1 minute', now() + interval '1 hour', 0.50, 0.40
  ) returning id into budget_id;

  reservation := public.reserve_model_budget(budget_id, decision_id, 0.40, 300);
  if reservation.status <> 'reserved'
     or (select reserved_usd from public.budgets where id = budget_id) <> 0.40 then
    raise exception 'model budget reservation was not recorded';
  end if;

  settled := public.settle_model_budget(reservation.id, 0.35);
  if settled.status <> 'settled'
     or (select reserved_usd from public.budgets where id = budget_id) <> 0
     or (select spent_usd from public.budgets where id = budget_id) <> 0.35 then
    raise exception 'model budget settlement was not reconciled';
  end if;

  begin
    insert into public.model_routing_decisions (
      workspace_id, task_profile_id, routing_policy_id,
      selected_model_deployment_id, candidate_snapshot,
      estimated_cost_usd, reason
    ) values (
      workspace_a, profile_id, policy_id, deployment_id, '[]'::jsonb,
      0.20, 'hard-limit smoke'
    ) returning id into second_decision_id;
    perform public.reserve_model_budget(budget_id, second_decision_id, 0.20, 300);
  exception when others then
    hard_limit_blocked := true;
  end;
  if not hard_limit_blocked then
    raise exception 'venture model hard limit was not enforced';
  end if;

  begin
    update public.budgets set venture_id = null where id = budget_id;
  exception when others then
    cross_scope_budget_blocked := true;
  end;
  if not cross_scope_budget_blocked then
    raise exception 'venture budget scope could be detached';
  end if;
end;
$$;

do $$
declare
  organization_id uuid;
  venture_id uuid;
  workspace_id uuid;
  manager_id uuid;
  worker_id uuid;
  environment_id uuid;
  runtime_instance_id uuid := gen_random_uuid();
  binding public.agent_runtime_bindings;
  parent_work public.work_items;
  child_work public.work_items;
  signal public.dispatch_signals;
  registration jsonb;
begin
  insert into public.organizations (slug, name)
  values ('runtime-' || gen_random_uuid()::text, 'Runtime Smoke Organization')
  returning id into organization_id;

  insert into public.ventures (organization_id, slug, name)
  values (organization_id, 'runtime-venture', 'Runtime Venture')
  returning id into venture_id;

  insert into public.workspaces (
    organization_id, venture_id, slug, name, kind
  ) values (
    organization_id, venture_id, 'runtime-workspace', 'Runtime Workspace', 'business'
  ) returning id into workspace_id;

  registration := public.register_agent(
    workspace_id, gen_random_uuid(),
    'scrypt$16384$8$1$runtime-manager$runtime-manager-hash',
    'runtime-manager-' || gen_random_uuid()::text, 'runtime smoke manager',
    2::smallint, array['delegate'], 1::smallint, 'smoke', null, '{}'::jsonb
  );
  manager_id := (registration->'agent'->>'id')::uuid;

  registration := public.register_agent(
    workspace_id, gen_random_uuid(),
    'scrypt$16384$8$1$runtime-worker$runtime-worker-hash',
    'runtime-worker-' || gen_random_uuid()::text, 'runtime smoke worker',
    1::smallint, array['research'], 1::smallint, 'smoke', null, '{}'::jsonb
  );
  worker_id := (registration->'agent'->>'id')::uuid;

  insert into public.worker_environments (
    organization_id, venture_id, workspace_id, slug, name, provider,
    runtime_type, isolation_level, expected_poll_interval_seconds
  ) values (
    organization_id, venture_id, workspace_id, 'shared-grok', 'Shared Grok',
    'xai', 'grok_bot', 'shared_account', 300
  ) returning id into environment_id;

  select * into binding from public.heartbeat_agent_runtime(
    worker_id, environment_id, runtime_instance_id,
    'agent-runtime/0.5.0', true, '{"smoke":true}'::jsonb
  );
  if binding.agent_id <> worker_id or binding.status <> 'online' then
    raise exception 'runtime heartbeat did not create an online binding';
  end if;

  insert into public.work_items (
    workspace_id, requested_by, assigned_to, work_type, title,
    required_capabilities
  ) values (
    workspace_id, manager_id, worker_id, 'runtime-smoke', 'Parent Work',
    array['research']
  ) returning * into parent_work;

  insert into public.work_items (
    workspace_id, parent_id, requested_by, assigned_to, work_type, title,
    required_capabilities
  ) values (
    workspace_id, parent_work.id, manager_id, worker_id,
    'runtime-smoke-child', 'Child Work', array['research']
  ) returning * into child_work;

  if child_work.trace_id <> parent_work.trace_id then
    raise exception 'child work did not inherit the parent trace';
  end if;

  select * into signal from public.pull_dispatch_signals(
    binding.id, worker_id, 20
  ) where work_item_id = parent_work.id;
  if signal.id is null or signal.status <> 'delivered' then
    raise exception 'durable work signal was not delivered';
  end if;

  update public.dispatch_signals
  set available_at = now() - interval '1 second'
  where id = signal.id;
  select * into signal from public.pull_dispatch_signals(
    binding.id, worker_id, 20
  ) where work_item_id = parent_work.id;
  if signal.delivery_attempts <> 2 then
    raise exception 'unacknowledged dispatch signal was not redelivered';
  end if;

  perform public.acknowledge_dispatch_signal(signal.id, worker_id);
  if (select status from public.dispatch_signals where id = signal.id)
     <> 'acknowledged' then
    raise exception 'dispatch signal was not acknowledged';
  end if;

  insert into public.artifacts (
    workspace_id, work_item_id, created_by, name, artifact_version,
    uri, media_type, sha256, byte_size, data_classification
  ) values (
    workspace_id, parent_work.id, worker_id, 'report.json', 1,
    'storage://runtime-smoke/report.json', 'application/json',
    repeat('a', 64), 128, 'internal'
  );

  update public.agent_runtime_bindings
  set last_seen_at = now() - interval '1 hour'
  where id = binding.id;
  perform public.run_worker_watchdog();
  if (select status from public.agent_runtime_bindings where id = binding.id)
     <> 'offline' then
    raise exception 'watchdog did not offline the stale runtime';
  end if;

  if not exists (
    select 1 from cron.job where jobname = 'ventureos-worker-watchdog'
  ) then
    raise exception 'worker watchdog schedule was not created';
  end if;
end;
$$;

rollback;

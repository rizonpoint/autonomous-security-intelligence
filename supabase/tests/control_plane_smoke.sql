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
      'eval_results'
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
      'reserve_budget', 'compare_and_swap_shared_state'
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

  insert into public.workspaces (
    organization_id, slug, name, kind, purpose
  ) values (
    organization_id, 'business-a', 'Business A', 'business', 'isolation smoke test'
  ) returning id into workspace_a;

  insert into public.workspaces (
    organization_id, slug, name, kind, purpose
  ) values (
    organization_id, 'personal-b', 'Personal B', 'personal', 'isolation smoke test'
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
    'personal-agent-' || gen_random_uuid()::text, 'personal smoke agent',
    1::smallint, array['research'], 1::smallint, 'smoke',
    now() + interval '1 hour', '{}'::jsonb
  );
  agent_b := (registration->'agent'->>'id')::uuid;

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

rollback;

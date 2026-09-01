-- Run after both control-plane migrations. The transaction is always rolled back.
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
      'agents', 'agent_credentials', 'work_items', 'messages', 'shared_state',
      'artifacts', 'approvals', 'audit_events', 'work_attempts', 'policy_versions',
      'tool_versions', 'action_outbox', 'control_flags', 'budgets', 'usage_ledger',
      'eval_results'
    )
    and (not c.relrowsecurity or not c.relforcerowsecurity);

  if unsafe_tables <> 0 then
    raise exception '% control-plane tables do not have RLS and FORCE RLS enabled', unsafe_tables;
  end if;

  select count(*) into unsafe_functions
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'claim_next_work_item', 'requeue_expired_work_items', 'heartbeat_work_attempt',
      'complete_work_attempt', 'fail_work_attempt', 'reserve_budget',
      'compare_and_swap_shared_state'
    )
    and p.prosecdef;

  if unsafe_functions <> 0 then
    raise exception '% operational functions still use SECURITY DEFINER', unsafe_functions;
  end if;

  if has_function_privilege('anon', 'public.claim_next_work_item(uuid, integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.claim_next_work_item(uuid, integer)', 'EXECUTE') then
    raise exception 'claim function is executable by a public API role';
  end if;
end;
$$;

do $$
declare
  test_agent_id uuid;
  first_work_id uuid;
  second_work_id uuid;
  claimed public.work_items;
  second_claim public.work_items;
  stale_completion_blocked boolean := false;
begin
  insert into public.agents (
    name, role, status, capabilities, max_concurrency
  ) values (
    'smoke-agent-' || gen_random_uuid()::text,
    'smoke test',
    'idle',
    array['job_search'],
    1
  ) returning id into test_agent_id;

  insert into public.work_items (work_type, title, priority, required_capabilities)
  values ('smoke', 'first claim', 100, array['job_search'])
  returning id into first_work_id;

  insert into public.work_items (work_type, title, priority, required_capabilities)
  values ('smoke', 'second claim', 90, array['job_search'])
  returning id into second_work_id;

  select * into claimed from public.claim_next_work_item(test_agent_id, 60);
  if claimed.id <> first_work_id or claimed.lease_token is null then
    raise exception 'atomic claim or lease fencing failed';
  end if;

  select * into second_claim from public.claim_next_work_item(test_agent_id, 60);
  if second_claim.id is not null then
    raise exception 'max_concurrency was not enforced';
  end if;

  perform public.complete_work_attempt(
    claimed.id,
    test_agent_id,
    claimed.lease_token,
    claimed.lease_version,
    '{"ok": true}'::jsonb
  );

  begin
    perform public.complete_work_attempt(
      claimed.id,
      test_agent_id,
      claimed.lease_token,
      claimed.lease_version,
      '{"ok": false}'::jsonb
    );
  exception when others then
    stale_completion_blocked := true;
  end;

  if not stale_completion_blocked then
    raise exception 'stale lease was allowed to complete work twice';
  end if;

  select * into second_claim from public.claim_next_work_item(test_agent_id, 60);
  if second_claim.id <> second_work_id then
    raise exception 'agent could not claim after completing prior work';
  end if;
end;
$$;

do $$
declare
  saved public.shared_state;
  conflict_detected boolean := false;
begin
  select * into saved from public.compare_and_swap_shared_state(
    'smoke', 'cas', '{"value": 1}'::jsonb, 0, null
  );
  if saved.version <> 1 then
    raise exception 'shared state insert version is incorrect';
  end if;

  select * into saved from public.compare_and_swap_shared_state(
    'smoke', 'cas', '{"value": 2}'::jsonb, 1, null
  );
  if saved.version <> 2 then
    raise exception 'shared state update version is incorrect';
  end if;

  begin
    perform public.compare_and_swap_shared_state(
      'smoke', 'cas', '{"value": 3}'::jsonb, 1, null
    );
  exception when others then
    conflict_detected := true;
  end;

  if not conflict_detected then
    raise exception 'stale shared state update was accepted';
  end if;
end;
$$;

do $$
declare
  work_id uuid;
  approval_id uuid;
  tamper_blocked boolean := false;
  outbound_blocked boolean := false;
begin
  insert into public.work_items (work_type, title)
  values ('smoke', 'approval and outbox')
  returning id into work_id;

  insert into public.approvals (
    work_item_id, action_type, summary, payload, risk, status
  ) values (
    work_id, 'email.send', 'smoke', '{"body": "approved"}'::jsonb, 'high', 'approved'
  ) returning id into approval_id;

  begin
    update public.approvals
    set payload = '{"body": "tampered"}'::jsonb
    where id = approval_id;
  exception when others then
    tamper_blocked := true;
  end;

  if not tamper_blocked then
    raise exception 'approved payload mutation was accepted';
  end if;

  begin
    insert into public.action_outbox (
      work_item_id, approval_id, action_type, payload, payload_sha256,
      idempotency_key, status
    ) values (
      work_id,
      approval_id,
      'email.send',
      '{"body": "approved"}'::jsonb,
      encode(digest(convert_to('{"body": "approved"}'::jsonb::text, 'UTF8'), 'sha256'), 'hex'),
      'smoke-' || gen_random_uuid()::text,
      'ready'
    );
  exception when others then
    outbound_blocked := true;
  end;

  if not outbound_blocked then
    raise exception 'global outbound-action kill switch failed';
  end if;
end;
$$;

do $$
declare
  test_scope_id text := 'smoke-' || gen_random_uuid()::text;
  first_reservation boolean;
  second_reservation boolean;
begin
  insert into public.budgets (
    scope_type, scope_id, period_start, period_end, hard_limit_usd
  ) values (
    'global', test_scope_id, now() - interval '1 minute',
    now() + interval '1 hour', 1.00
  );

  first_reservation := public.reserve_budget('global', test_scope_id, 0.40);
  second_reservation := public.reserve_budget('global', test_scope_id, 0.70);

  if not first_reservation or second_reservation then
    raise exception 'hard budget cap was not enforced';
  end if;
end;
$$;

rollback;

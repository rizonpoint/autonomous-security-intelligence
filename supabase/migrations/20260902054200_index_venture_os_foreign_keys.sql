begin;

-- Cover v0.4 foreign-key paths used by venture lifecycle operations, model
-- routing, evaluation, usage accounting, and blueprint provisioning.
create index if not exists budgets_venture_idx
  on public.budgets (venture_id)
  where venture_id is not null;

create index if not exists eval_results_task_profile_idx
  on public.eval_results (task_profile_id)
  where task_profile_id is not null;

create index if not exists model_deployments_organization_idx
  on public.model_deployments (organization_id);

create index if not exists model_routing_decisions_attempt_idx
  on public.model_routing_decisions (attempt_id)
  where attempt_id is not null;

create index if not exists model_routing_decisions_policy_idx
  on public.model_routing_decisions (routing_policy_id)
  where routing_policy_id is not null;

create index if not exists model_routing_decisions_selected_deployment_idx
  on public.model_routing_decisions (selected_model_deployment_id)
  where selected_model_deployment_id is not null;

create index if not exists model_routing_decisions_work_item_fk_idx
  on public.model_routing_decisions (work_item_id)
  where work_item_id is not null;

create index if not exists task_profiles_venture_idx
  on public.task_profiles (venture_id)
  where venture_id is not null;

create index if not exists usage_ledger_model_deployment_idx
  on public.usage_ledger (model_deployment_id)
  where model_deployment_id is not null;

create index if not exists usage_ledger_routing_decision_idx
  on public.usage_ledger (routing_decision_id)
  where routing_decision_id is not null;

create index if not exists venture_blueprint_instances_version_idx
  on public.venture_blueprint_instances (blueprint_version_id);

create index if not exists venture_blueprints_organization_idx
  on public.venture_blueprints (organization_id)
  where organization_id is not null;

commit;

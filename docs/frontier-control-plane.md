# Frontier Control-Plane Practices

This document records the production patterns intentionally applied to the
control plane. The goal is not to imitate one framework; it is to preserve the
reliability properties shared by mature agent runtimes.

## Applied patterns

### Durable, replayable execution

Workflow state and individual attempts are stored separately. A work item is the
durable objective; every execution or retry creates an immutable attempt. This
mirrors durable workflow systems that recover from the latest persisted state
and use event history for replay.

Sources:

- https://docs.temporal.io/workflow-execution
- https://docs.temporal.io/encyclopedia/retry-policies
- https://openai.github.io/openai-agents-python/running_agents/

### Idempotent, granular side effects

External actions are represented in a transactional outbox with an idempotency
key. A retry cannot silently send the same email, publish the same content, or
make the same purchase twice. Large activities should be split so only the
failed side effect is retried.

Source: https://docs.temporal.io/activity-definition

### Exact-payload human approval

Approval pauses work and serializes the pending action. The approved payload is
hashed; changing the payload requires a new approval. Approval is not a general
permission grant.

Source: https://openai.github.io/openai-agents-python/human_in_the_loop/

### Full tracing and evaluation

Trace, span, work-item, attempt, model, tool, policy, and prompt versions are
recorded separately. This supports debugging, replay, regression evaluation,
cost analysis, and model/provider comparisons.

Sources:

- https://openai.github.io/openai-agents-python/tracing/
- https://openai.github.io/openai-agents-python/guardrails/

### Least privilege and secret separation

All exposed tables have RLS enabled and default grants revoked. Agent runtimes
never receive the service-role credential. Encrypted third-party credentials
belong in Vault or a dedicated secret manager, not state, messages, or events.

Sources:

- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/database/vault

### Operational brakes

Global and scoped control flags pause new claims or disable outbound actions.
Budgets are modeled as hard limits, not dashboard-only metrics. A worker should
fail closed when it cannot verify policy, approval, or budget state.

## Deliberate omissions

The database is not pretending to be a complete Temporal replacement. If the
workflows become long-lived or highly branched, a durable execution engine can
own orchestration while this control plane remains the identity, policy,
approval, audit, and business-state layer.

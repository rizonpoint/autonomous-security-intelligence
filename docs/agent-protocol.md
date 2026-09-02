# Agent Protocol v0.3

## Identity

Every worker has a stable `agent_id`, immutable `workspace_id`, role, authority
level, capability list, and individually revocable API credential. Human
operators are represented separately in approval resolution metadata.

An agent may operate only inside its registered workspace. It cannot claim,
read, message, update state, request approval, or consume budget across a
workspace boundary.

## Work-item lifecycle

```text
queued -> claimed -> running -> completed
                    |       \
                    |        -> waiting_approval -> completed
                    -> failed -> queued (retry) -> dead_letter
```

An agent must never assume a claim is permanent. Claims have a lease expiration.
A worker renews its lease while active; an expired claim can be recovered.

### Claim rules

1. Claim only work matching the agent's registered capabilities.
2. Claim atomically through `claim_next_work_item`; never select and update in
   separate requests.
3. Include an idempotency key when creating work.
4. Do not claim another item while the current item is `running` unless the
   agent's concurrency policy explicitly permits it.

## Messaging

Messages coordinate work but do not replace work-item state.

- `task`: request another agent to perform bounded work
- `result`: return structured results
- `question`: request missing information
- `review`: request QA or red-team review
- `system`: control-plane notification

Every task or result message should reference a `work_item_id`. Broadcasts are
allowed only for system notifications.

## Shared state

State uses `(workspace_id, namespace, key)` plus an integer version. Updates are
compare-and-swap operations: a writer supplies the version it read, preventing
silent overwrites. Examples include `accounts/acme`, `delivery/client-a`, and
`company/operating_policy`.

## Approval contract

Agents create an approval request containing:

- proposed action and rationale
- exact payload that would be executed
- risk level
- expiration time
- linked work item and requesting agent

The agent must treat anything except `approved` as denied. Approval of one exact
payload does not authorize a modified payload or future similar actions.

## Minimum events

Agents emit events for `registered`, `heartbeat`, `claimed`, `started`,
`tool_called`, `message_sent`, `approval_requested`, `completed`, `failed`, and
`released`. Tool events may include latency, token use, and estimated cost, but
never secrets.

## Permanent business roster

| Agent | Capabilities | Starting authority |
|---|---|---:|
| Chief of Staff / CEO | orchestrate, prioritize, delegate, escalate | L2 |
| Market Intelligence | market_research, signal_detection, account_research | L1 |
| Prospecting | prospect_research, qualify_account, contact_research | L1 |
| Sales | discovery_prep, draft_outreach, draft_proposal | L2 |
| Delivery | produce_brief, analyze_signals, build_artifact | L1 |
| Customer Success | client_health, renewal_prep, feedback_synthesis | L1 |
| Finance / Ops | budget_monitor, revenue_tracking, operating_report | L1 |
| Red Team / QA | fact_check, policy_check, reject_output | L2 |
| Human Approver | resolve_approval | Human |

Job Scout and related employment agents are optional temporary workers in a
separate Personal Income workspace. They are not part of the company hierarchy.

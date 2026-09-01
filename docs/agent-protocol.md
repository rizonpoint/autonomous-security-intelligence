# Agent Protocol v0.1

## Identity

Every worker has a stable `agent_id`, role, authority level, capability list,
and individually revocable API credential. Human operators are represented
separately in approval resolution metadata.

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

State uses `(namespace, key)` plus an integer version. Updates are compare-and-
swap operations: a writer supplies the version it read, preventing silent
overwrites. Examples include `accounts/acme`, `job_search/daily_targets`, and
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

## First agent roles

| Agent | Capabilities | Starting authority |
|---|---|---:|
| Job Scout | job_search, verify_listing, rank_role | L1 |
| Application Researcher | company_research, people_research | L1 |
| Business Development | prospect_research, qualify_account | L1 |
| Proposal Builder | scope_workflow, draft_proposal | L1 |
| QA / Red Team | fact_check, policy_check, reject_output | L1 |
| Human Approver | resolve_approval | Human |

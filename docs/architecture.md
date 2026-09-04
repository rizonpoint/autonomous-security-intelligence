# Control Plane Architecture

## Goal

Create one auditable coordination layer that multiple businesses and agent
runtimes can use. The database is the source of truth; conversations are not.

## Tenant, venture, and workspace model

- **Organization:** the tenant, ownership, and future white-label boundary.
- **Venture:** one revenue thesis, operating company, client venture, proof of
  concept, or sandbox beneath that tenant.
- **Department workspace:** an execution boundary inside a venture, such as
  Executive, Market Intelligence, Sales, Delivery, or Red Team / QA.
- **Client workspace:** isolated delivery, context, approvals, and budgets for
  one customer when needed.
- **Internal workspace:** tenant-level platform or administrative work that can
  remain outside a venture.

Every operational record carries a `workspace_id`. Composite foreign keys and
workspace-aware RPCs reject cross-workspace references even when a caller knows
another record's UUID. An agent keeps an immutable home workspace and can gain
explicit memberships in other workspaces belonging to the same tenant.

The current cybersecurity workspace remains the first venture's legacy root
workspace so active worker keys and leases do not change. New ventures should
use department workspaces from the beginning.

## Boundaries

| Component | Responsibility | Trust boundary |
|---|---|---|
| Agent runtime | Performs one bounded role | Receives only a scoped API key |
| Control Plane API | Authentication, authorization, validation, orchestration | Holds database service credentials |
| Supabase/Postgres | Durable state, work queue, messages, approvals, audit | Private; never exposed with service key to agents |
| Human approver | Resolves consequential decisions | Required for send, spend, publish, delete, permissions, production |

The model provider is not the agent identity. One durable agent role can be
routed to different eligible model deployments per task profile. Every routing
decision records the candidates, policy, price snapshot, estimate, selection,
and subsequent eval evidence.

## Authority levels

| Level | Allowed behavior |
|---|---|
| L0 Observe | Read and research only |
| L1 Prepare | Create internal drafts, analyses, and recommendations |
| L2 Approval | Propose consequential actions; execution waits for approval |
| L3 Reversible | Execute low-risk, reversible actions within a written policy |
| L4 Bounded | Execute narrowly bounded consequential actions; not used initially |

## Core flow

1. An agent authenticates and sends a heartbeat.
2. It atomically claims one compatible work item for a bounded lease.
3. It records progress events and may message another agent.
4. Consequential work creates an approval request instead of executing.
5. The agent completes, fails, or releases the work item.
6. Failed work is retried up to its configured limit, then dead-lettered.

Each claim creates a separate immutable attempt with a new fencing token. Any
completion, failure, heartbeat, or external action must present the current
token and lease version; stale workers are rejected even if they wake up later.

## Security decisions

- Supabase row-level security is enabled on every public table.
- No public table receives an `anon` or `authenticated` policy in v0.1.
- Only the control-plane backend uses the service-role credential.
- Agent credentials are stored as bounded, salted `scrypt` hashes with
  credential-scoped expiration and revocation fields.
- Approval payloads and audit events are immutable from agent-facing workflows.
- Approved action payloads are hashed and delivered through an idempotent outbox.
- Global and workspace-scoped kill switches disable new claims and outbound
  actions independently.
- Policies, prompts, tools, and workflow versions are recorded on every run.
- External sends, publishing, purchases, deletion, permission changes, and
  production modifications require human approval.

## Why not direct agent-to-database access?

Direct access would force every agent environment to hold a powerful database
credential and would make authorization inconsistent. The API boundary gives us
one place to enforce role permissions, input validation, rate limits, leases,
idempotency, and audit logging.

# Autonomous Security Intelligence

A production-oriented multi-agent system for account research, signal detection,
qualification, QA, and human-approved outreach.

The first component is a provider-neutral **agent control plane**. It gives Grok
Bot, Codex, and future workers one shared place to coordinate work without
sharing chat history or database credentials directly.

## What v0.2 provides

- durable agent registry and capability metadata
- atomic work queue with ownership, leases, retries, and dead-letter handling
- agent-to-agent messages tied to work items
- versioned shared state and artifact references
- approval gates for consequential actions
- append-only audit events with latency and cost fields
- PostgreSQL/Supabase migration with private-by-default row-level security
- durable attempts, lease fencing, exact-payload approvals, and an action outbox
- versioned policies/tools plus kill switches, budgets, tracing, and eval records
- a deployed Supabase Edge gateway with custom, revocable agent authentication
- a portable FastAPI implementation with the same control-plane lifecycle

## Architecture

```text
Grok Bot ─┐
Codex ────┼──> Control Plane API ──> Supabase/Postgres
Workers ──┘          │                       │
                     └── approvals + audit ──┘
```

Agents never receive the Supabase service-role credential. They authenticate to
the control-plane API with individually revocable keys, and every meaningful
action is recorded.

## Repository layout

```text
control_plane_api/       FastAPI gateway and agent-key authentication
docs/
  architecture.md        system boundaries and authority model
  agent-protocol.md       job, message, approval, and heartbeat protocol
  control-plane-api.md    gateway setup and endpoint lifecycle
  edge-gateway.md         hosted Edge deployment and verification
supabase/migrations/
  202609010001_control_plane.sql
  202609010002_frontier_hardening.sql
supabase/functions/
  control-plane/          deployed Deno/TypeScript gateway adapter
supabase/tests/
  control_plane_smoke.sql
tests/                    FastAPI and credential unit tests
```

## API quick start

```bash
cp .env.example .env
uv sync --group dev
uv run pytest -q
uv run uvicorn control_plane_api.main:app --reload
```

See [Control-Plane API](docs/control-plane-api.md) for the security boundary and
agent workflow.

## Hosted status

The schema and `control-plane` Edge Function are deployed to the hosted Supabase
development project. Live verification covers public health, protected-route
denial, and fail-closed administration. Outbound actions remain disabled.

The next milestone configures the administrator project secret, issues scoped
keys to Job Scout and Researcher, and runs the first end-to-end work handoff.

See [architecture](docs/architecture.md), the [agent protocol](docs/agent-protocol.md),
and the documented [frontier control-plane practices](docs/frontier-control-plane.md).

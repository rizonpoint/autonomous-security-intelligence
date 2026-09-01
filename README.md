# Autonomous Security Intelligence

A production-oriented multi-agent system for account research, signal detection,
qualification, QA, and human-approved outreach.

The first component is a provider-neutral **agent control plane**. It gives Grok
Bot, Codex, and future workers one shared place to coordinate work without
sharing chat history or database credentials directly.

## What v0.1 provides

- durable agent registry and capability metadata
- atomic work queue with ownership, leases, retries, and dead-letter handling
- agent-to-agent messages tied to work items
- versioned shared state and artifact references
- approval gates for consequential actions
- append-only audit events with latency and cost fields
- PostgreSQL/Supabase migration with private-by-default row-level security

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
docs/
  architecture.md        system boundaries and authority model
  agent-protocol.md       job, message, approval, and heartbeat protocol
supabase/migrations/
  202609010001_control_plane.sql
```

## Status

The control-plane schema and protocol are the first shipped milestone. The next
milestone applies the migration to a hosted Supabase project and exposes the
minimal API used by the first Job Scout and Research agents.

See [architecture](docs/architecture.md) and the [agent protocol](docs/agent-protocol.md).

# Autonomous Worker Runtime

VentureOS treats model providers and Bot products as replaceable execution
runtimes. PostgreSQL owns workflow truth; provider schedulers only wake a
worker to poll it.

## Authority model

| Layer | Responsibility | Never authoritative for |
|---|---|---|
| Work item | objective, assignee, priority, trace, status | provider UI state |
| Work attempt | lease, fencing token, heartbeat, retry | a Bot saying it is busy |
| Worker environment | provider and declared isolation boundary | an agent credential |
| Runtime binding | instance liveness and poll history | task completion |
| Dispatch signal | durable wake-up with redelivery | ownership of the work |
| Artifact manifest | versioned output identity and checksum | the underlying secret |

## Trust zones

`shared_account` is the correct declaration for multiple Grok Bots using one
persistent Grok computer. The roles may have separate VentureOS credentials,
but they share filesystem and browser state. Higher-isolation ventures can use
`dedicated_identity`, `microvm`, or `dedicated_host` environments without
changing the worker protocol.

Isolation is admin-declared. A worker heartbeat cannot promote its own
environment or attest itself as verified.

## Durable wake-up behavior

1. Work creation inherits the parent's trace automatically.
2. Assigned queued work creates an idempotent dispatch signal for each active
   runtime binding.
3. Polling marks a signal delivered and moves its visibility five minutes into
   the future.
4. A successful claim acknowledges the matching signal.
5. If the worker crashes first, the signal becomes visible again.
6. The watchdog degrades or offlines stale bindings and independently requeues
   expired work leases.

This makes a missed Grok routine a latency event rather than a lost-work event.

## Operational rollout

The database migration and Edge Function must deploy together. After deployment:

1. Create one `grok_bot` / `shared_account` environment for the cybersecurity
   venture through the admin API.
2. Give every Grok Bot the same public environment ID but keep its existing,
   individual `asi.*` agent key.
3. Replace claim-only routines with the `poll` command.
4. Schedule `public.run_worker_watchdog()` through `pg_cron` at one-minute
   intervals. No provider or model secret is needed for this database-local
   check.
5. Register structured outputs through the artifact-manifest endpoint.

Outbound actions remain governed by the existing approval and kill-switch
controls. Worker liveness does not grant additional authority.

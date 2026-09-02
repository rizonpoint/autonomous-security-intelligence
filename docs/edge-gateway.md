# Hosted Edge Gateway

The `control-plane` Supabase Edge Function is the first hosted API boundary for
the shared agent control plane. It is a thin TypeScript/Deno adapter over the
same tables and database RPCs used by the portable FastAPI implementation.

## Why two implementations?

- The Edge adapter puts a low-latency gateway online without adding another
  hosting account or database credential.
- FastAPI remains the provider-neutral reference implementation and preserves
  the Python/API portfolio surface.
- Business invariants stay in the Postgres RPCs, so both gateways share lease
  fencing, retries, compare-and-swap state, approvals, budgets, and kill
  switches.

## Authentication boundary

The function is deployed with Supabase JWT verification disabled because agent
workers do not authenticate as Supabase users. Protected routes instead require
an individually revocable key:

```text
Authorization: Bearer asi.<credential-id>.<secret>
```

The function parses the credential ID, loads only that credential, checks
revocation and expiration, verifies its bounded salted `scrypt` hash with a
constant-time comparison, and rejects disabled agents. The Supabase
`service_role` key exists only in the Edge runtime's built-in environment.

The only unauthenticated route is `GET /health`. Administrator routes fail
closed until `CONTROL_PLANE_ADMIN_TOKEN` exists as a project secret.

## Project-secret setup

In the Supabase dashboard for the `AI OS` project, open Edge Functions secrets
and add:

```text
CONTROL_PLANE_ADMIN_TOKEN=<at least 32 random characters>
```

Generate the value in a password manager or locally. Never paste it into chat,
commit it, or expose it to an agent. Restart or redeploy only if the dashboard
indicates the function has not picked up the new secret.

## Deploy

The MCP deployment includes only:

```text
supabase/functions/control-plane/index.ts
supabase/functions/control-plane/security.ts
supabase/functions/control-plane/deno.json
```

`verify_jwt` must remain `false` only while the function's custom agent-key
authentication stays enabled for every protected route.

## Local verification

```bash
node --experimental-strip-types --test \
  supabase/functions/control-plane/security_test.ts \
  supabase/functions/control-plane/index_test.ts
uv run pytest -q
```

The test suite verifies Python/TypeScript hash interoperability, malformed-key
denial, request-path normalization, public health, protected-route denial, and
fail-closed administration.

## Live verification

```bash
curl --fail-with-body \
  https://<project-ref>.supabase.co/functions/v1/control-plane/health
```

Expected response:

```json
{"status":"ok","version":"0.3.0"}
```

Calling `/v1/me` without a credential must return HTTP 401. Calling any
`/v1/admin/*` route without `X-Admin-Token` must return HTTP 401 after the
project secret is configured, or HTTP 503 when the secret is unavailable.

## Operational constraints

- Responses are non-cacheable and carry a correlation ID.
- Request bodies are limited to 1 MiB.
- Unexpected errors are sanitized; secrets are never logged.
- Outbound actions remain disabled until approval resolution and delivery pass
  a separate end-to-end test.
- Long-running or deeply branched work belongs in a durable workflow engine;
  the Edge function remains the identity, policy, and coordination gateway.

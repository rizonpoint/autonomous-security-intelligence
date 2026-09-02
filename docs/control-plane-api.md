# Control-Plane API

The control-plane gateway is the only supported path from an agent runtime to
Supabase. The portable implementation uses FastAPI; the first hosted adapter
uses a Supabase Edge Function. Both preserve the same authentication and work
lifecycle. Grok Bot, Codex, and future workers never receive a Supabase database
password or service-role key.

## Security boundary

1. The server holds `SUPABASE_SERVICE_ROLE_KEY` in its secret environment.
2. An administrator creates an agent using `CONTROL_PLANE_ADMIN_TOKEN`.
3. The API returns one plaintext key in the form `asi.<credential-id>.<secret>`.
4. Only a salted `scrypt` hash is stored in `agent_credentials`.
5. Every agent request uses its own bearer key.
6. A key can be expired or revoked without affecting other agents.

The public Supabase roles have explicit deny-all RLS policies. Operational RPCs
use `SECURITY INVOKER` and are executable only by `service_role`.

## Local setup

```bash
cp .env.example .env
uv sync --group dev
uv run uvicorn control_plane_api.main:app --reload
```

Open `http://127.0.0.1:8000/docs` for the generated OpenAPI interface.

Never commit `.env`, an agent plaintext key, the admin token, or the Supabase
service-role key.

## Core lifecycle

### Create an agent

`POST /v1/admin/agents` with the `X-Admin-Token` header. The response displays
the agent key once. Store it in that worker's scoped secret manager.

### Authenticate

Agent endpoints require:

```text
Authorization: Bearer asi.<credential-id>.<secret>
```

### Coordinate work

1. `POST /v1/work-items` creates an idempotent unit of work.
2. `POST /v1/work-items/claim` atomically claims eligible work using registered
   capabilities and the agent's concurrency limit.
3. `POST /v1/work-items/{id}/heartbeat` renews a fenced lease.
4. `POST /v1/work-items/{id}/complete` or `/fail` closes the current attempt.
5. Stale lease tokens cannot mutate work after another attempt takes ownership.

### Communicate and share state

- `POST /v1/messages` sends a work-linked agent message.
- `GET /v1/messages/inbox` reads the authenticated agent's inbox.
- `GET /v1/state/{namespace}/{key}` reads durable shared state.
- `PUT /v1/state/{namespace}/{key}` performs a compare-and-swap write using
  `expected_version`; stale writers receive a conflict.

### Request consequential action

`POST /v1/approvals` serializes the exact proposed payload and its risk level.
The database hashes that payload. Any modification requires a new approval. The
outbound-action kill switch remains enabled until the human approval UI and
delivery worker pass end-to-end tests.

## Verification

```bash
uv run pytest -q
```

Database behavior is verified separately by
`supabase/tests/control_plane_smoke.sql`. It runs in a transaction and rolls
back its fixtures.

The Edge adapter is verified with:

```bash
node --experimental-strip-types --test \
  supabase/functions/control-plane/security_test.ts \
  supabase/functions/control-plane/index_test.ts
```

See [Hosted Edge Gateway](edge-gateway.md) for deployment and live probes.

# Grok Bot Runtime

Grok Bot can operate as one provider runtime for VentureOS. The Bot
uses its persistent cloud computer to run the repository's scoped worker CLI;
it never receives a Supabase key or the control-plane administrator token.

## Security boundary

All Grok Bots on one account share the same cloud computer, files, browser
sessions, and command-line credentials. Bot names are therefore workflow roles,
not credential-isolation boundaries.

- Never place `CONTROL_PLANE_ADMIN_TOKEN` or a Supabase service key on Grok's
  computer.
- Provision only the one low-authority `asi.*` credential a Bot currently
  needs.
- Keep external sending and purchases disabled behind control-plane approval.
- Use separate infrastructure when cryptographic isolation between workers is
  required.

VentureOS records the shared Grok computer as a `shared_account` worker
environment. Separate Bot names do not change that trust-zone declaration.
Use separate Grok users/computers for identity isolation; use a managed microVM
or dedicated host when the venture requires an independently attested runtime.

## Scheduling boundary

Grok routines are wake-up hints, not workflow state. A delayed or skipped
routine cannot lose an assignment because the authoritative item, lease,
retry count, trace, and completion state live in Postgres. Each routine should
run one `poll` command and let VentureOS decide what is available.

```bash
python -m agent_runtime.cli \
  --key-file ~/.config/asi/agents/market-intelligence.key \
  poll \
  --environment-id "$ASI_WORKER_ENVIRONMENT_ID" \
  --routine-triggered \
  --lease-seconds 900
```

The first poll creates a stable, private `*.runtime.json` file beside the
agent key. Later polls reuse that runtime instance ID, heartbeat the binding,
read inbox messages and durable dispatch signals, and claim at most one
compatible work item. A successfully matched work signal is acknowledged only
after the work claim succeeds.

## Worker lifecycle

Chief of Staff and other manager-authorized agents can delegate work through
the same scoped credential. The gateway requires authority level 2+ or an
explicit `delegate` capability. `work-create` accepts the gateway's typed
`WorkItemCreate` JSON contract and prints only the new work item's routing
summary:

```bash
python -m agent_runtime.cli \
  --key-file ~/.config/asi/agents/chief-of-staff.key \
  work-create --json-file red-team-assignment.json
```

The gateway always derives `requested_by` and `workspace_id` from the caller's
credential. A worker cannot impersonate another requester or create work in a
different workspace by changing the JSON file.

## Execution lifecycle

1. Authenticate with `python -m agent_runtime.cli ... me`.
2. Claim one compatible work item with a bounded lease. The CLI atomically
   stores the full claim beside the agent key as a mode-0600 `*.claim.json`
   file and prints only a sanitized summary.
3. Perform research with Grok Bot's browser and connected tools.
4. Heartbeat during long work.
5. Save the structured result to a JSON file.
6. Heartbeat, complete, or fail with `--claim-file`; the lease token never
   needs to appear in chat or a process command line.
7. Message Red Team / QA with the linked work-item ID.

Structured deliverables should also be registered with `artifact`. The
manifest records the filename, version, URI, media type, checksum,
classification, and work item so downstream agents can retrieve the correct
version without relying on chat attachments.

The CLI never accepts an agent key as a command-line value. It reads a mode-0600
file supplied through `--key-file` or `ASI_AGENT_KEY_FILE` and never prints the
credential.

```bash
python -m agent_runtime.cli \
  --key-file ~/.config/asi/agents/market-intelligence.key \
  claim --lease-seconds 900

python -m agent_runtime.cli \
  --key-file ~/.config/asi/agents/market-intelligence.key \
  heartbeat \
  --claim-file ~/.config/asi/agents/market-intelligence.claim.json \
  --extend-seconds 600

python -m agent_runtime.cli \
  --key-file ~/.config/asi/agents/market-intelligence.key \
  claim-info \
  --claim-file ~/.config/asi/agents/market-intelligence.claim.json
```

`claim-info` displays the work specification while omitting the private lease
token.

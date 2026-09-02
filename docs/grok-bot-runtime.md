# Grok Bot Runtime

Grok Bot can operate as a provider runtime for Autonomous Companies OS. The Bot
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

## Worker lifecycle

1. Authenticate with `python -m agent_runtime.cli ... me`.
2. Claim one compatible work item with a bounded lease.
3. Perform research with Grok Bot's browser and connected tools.
4. Heartbeat during long work.
5. Save the structured result to a JSON file.
6. Complete or fail using the current lease token and version.
7. Message Red Team / QA with the linked work-item ID.

The CLI never accepts an agent key as a command-line value. It reads a mode-0600
file supplied through `--key-file` or `ASI_AGENT_KEY_FILE` and never prints the
credential.

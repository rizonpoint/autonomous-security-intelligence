from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from .client import (
    DEFAULT_CONTROL_PLANE_URL,
    ControlPlaneClient,
    ControlPlaneError,
    load_agent_key,
)


def json_file(path: str) -> dict[str, Any]:
    if path == "-":
        value = json.load(sys.stdin)
    else:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ControlPlaneError(2, "JSON input must be an object")
    return value


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Scoped Autonomous Companies worker CLI")
    root.add_argument(
        "--key-file",
        default=os.environ.get("ASI_AGENT_KEY_FILE"),
        help="Path to a mode-0600 asi.* agent key file",
    )
    root.add_argument(
        "--base-url",
        default=os.environ.get("CONTROL_PLANE_URL", DEFAULT_CONTROL_PLANE_URL),
    )
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("me")

    claim = commands.add_parser("claim")
    claim.add_argument("--lease-seconds", type=int, default=900)

    for name in ("heartbeat", "complete", "fail"):
        command = commands.add_parser(name)
        command.add_argument("--work-item-id", required=True)
        command.add_argument("--lease-token", required=True)
        command.add_argument("--lease-version", required=True, type=int)
        if name == "heartbeat":
            command.add_argument("--extend-seconds", type=int, default=300)
        else:
            command.add_argument("--json-file", required=True)
        if name == "fail":
            command.add_argument("--failure-class", default="unknown")
            command.add_argument("--no-retry", action="store_true")

    message = commands.add_parser("message")
    message.add_argument("--to-agent", required=True)
    message.add_argument("--kind", choices=("task", "result", "question", "review"), required=True)
    message.add_argument("--work-item-id")
    message.add_argument("--json-file", required=True)

    approval = commands.add_parser("approval")
    approval.add_argument("--work-item-id", required=True)
    approval.add_argument("--action-type", required=True)
    approval.add_argument("--summary", required=True)
    approval.add_argument("--risk", choices=("low", "medium", "high", "critical"), required=True)
    approval.add_argument("--json-file", required=True)
    approval.add_argument("--expires-at")
    return root


def execute(args: argparse.Namespace) -> Any:
    if not args.key_file:
        raise ControlPlaneError(2, "--key-file or ASI_AGENT_KEY_FILE is required")
    client = ControlPlaneClient(load_agent_key(args.key_file), args.base_url)

    if args.command == "me":
        return client.me()
    if args.command == "claim":
        return client.claim(args.lease_seconds)
    if args.command == "heartbeat":
        return client.heartbeat(
            args.work_item_id,
            args.lease_token,
            args.lease_version,
            args.extend_seconds,
        )
    if args.command == "complete":
        return client.complete(
            args.work_item_id,
            args.lease_token,
            args.lease_version,
            json_file(args.json_file),
        )
    if args.command == "fail":
        return client.fail(
            args.work_item_id,
            args.lease_token,
            args.lease_version,
            json_file(args.json_file),
            args.failure_class,
            not args.no_retry,
        )
    if args.command == "message":
        return client.message(
            args.to_agent,
            args.kind,
            json_file(args.json_file),
            args.work_item_id,
        )
    if args.command == "approval":
        return client.request_approval(
            args.work_item_id,
            args.action_type,
            args.summary,
            json_file(args.json_file),
            args.risk,
            args.expires_at,
        )
    raise ControlPlaneError(2, "unsupported command")


def main() -> int:
    try:
        result = execute(parser().parse_args())
    except (ControlPlaneError, json.JSONDecodeError) as exc:
        detail = exc.detail if isinstance(exc, ControlPlaneError) else "invalid JSON input"
        print(json.dumps({"error": detail}), file=sys.stderr)
        return exc.status_code if isinstance(exc, ControlPlaneError) and exc.status_code < 126 else 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

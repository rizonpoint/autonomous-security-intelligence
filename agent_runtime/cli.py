from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any
from uuid import uuid4

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


def write_private_json(path: str | Path, value: dict[str, Any]) -> Path:
    target = Path(path).expanduser()
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        dir=target.parent,
        prefix=f".{target.name}.",
        suffix=".tmp",
    )
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        os.chmod(target, 0o600)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return target


def default_claim_file(key_file: str | Path) -> Path:
    key_path = Path(key_file).expanduser()
    return key_path.with_suffix(".claim.json")


def default_runtime_file(key_file: str | Path) -> Path:
    key_path = Path(key_file).expanduser()
    return key_path.with_suffix(".runtime.json")


def runtime_state(path: str | Path) -> tuple[Path, dict[str, Any]]:
    target = Path(path).expanduser()
    if target.exists():
        value = json_file(str(target))
    else:
        value = {"runtime_instance_id": str(uuid4())}
        write_private_json(target, value)
    if not value.get("runtime_instance_id"):
        raise ControlPlaneError(2, "runtime file is missing runtime_instance_id")
    return target, value


def sanitized_claim(value: dict[str, Any], claim_file: Path | None = None) -> dict[str, Any]:
    result = {
        "work_id": value.get("id") or value.get("work_id"),
        "title": value.get("title"),
        "status": value.get("status"),
        "queue": value.get("queue"),
        "lease_expires_at": value.get("lease_expires_at"),
        "lease_version": value.get("lease_version"),
        "trace_id": value.get("trace_id"),
    }
    if claim_file is not None:
        result["claim_file"] = str(claim_file)
    return result


def sanitized_work_item(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "work_id": value.get("id") or value.get("work_id"),
        "title": value.get("title"),
        "status": value.get("status"),
        "assigned_to": value.get("assigned_to"),
        "queue": value.get("queue"),
        "trace_id": value.get("trace_id"),
    }


def claim_info(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if key != "lease_token"}


def lease_fields(args: argparse.Namespace) -> tuple[str, str, int, Path | None]:
    claim_path = Path(args.claim_file).expanduser() if args.claim_file else None
    if claim_path is not None:
        claim = json_file(str(claim_path))
        work_item_id = claim.get("id") or claim.get("work_id")
        lease_token = claim.get("lease_token")
        lease_version = claim.get("lease_version")
    else:
        work_item_id = args.work_item_id
        lease_token = args.lease_token
        lease_version = args.lease_version

    if not work_item_id or not lease_token or lease_version is None:
        raise ControlPlaneError(
            2,
            "use --claim-file or provide --work-item-id, --lease-token, and --lease-version",
        )
    return str(work_item_id), str(lease_token), int(lease_version), claim_path


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Scoped VentureOS worker CLI")
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

    inbox = commands.add_parser("inbox")
    inbox.add_argument("--include-read", action="store_true")
    inbox.add_argument("--limit", type=int, default=100)

    poll = commands.add_parser("poll")
    poll.add_argument("--environment-id", required=True)
    poll.add_argument("--runtime-file")
    poll.add_argument("--runtime-version", default="agent-runtime/0.5.0")
    poll.add_argument("--routine-triggered", action="store_true")
    poll.add_argument("--lease-seconds", type=int, default=900)
    poll.add_argument("--claim-file")
    poll.add_argument("--no-claim", action="store_true")
    poll.add_argument("--message-limit", type=int, default=100)
    poll.add_argument("--signal-limit", type=int, default=20)

    work_create = commands.add_parser("work-create")
    work_create.add_argument(
        "--json-file",
        required=True,
        help="WorkItemCreate JSON object; use - to read standard input",
    )

    claim = commands.add_parser("claim")
    claim.add_argument("--lease-seconds", type=int, default=900)
    claim.add_argument(
        "--claim-file",
        help="Private destination for the full claim; defaults beside the agent key",
    )

    info = commands.add_parser("claim-info")
    info.add_argument("--claim-file", required=True)

    for name in ("heartbeat", "complete", "fail"):
        command = commands.add_parser(name)
        command.add_argument("--claim-file")
        command.add_argument("--work-item-id")
        command.add_argument("--lease-token")
        command.add_argument("--lease-version", type=int)
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

    artifact = commands.add_parser("artifact")
    artifact.add_argument("--json-file", required=True)

    artifacts = commands.add_parser("artifacts")
    artifacts.add_argument("--work-item-id", required=True)
    return root


def execute(args: argparse.Namespace) -> Any:
    if not args.key_file:
        raise ControlPlaneError(2, "--key-file or ASI_AGENT_KEY_FILE is required")
    client = ControlPlaneClient(load_agent_key(args.key_file), args.base_url)

    if args.command == "me":
        return client.me()
    if args.command == "inbox":
        return client.inbox(not args.include_read, args.limit)
    if args.command == "poll":
        runtime_path = Path(args.runtime_file).expanduser() if args.runtime_file else default_runtime_file(args.key_file)
        runtime_path, state = runtime_state(runtime_path)
        heartbeat = client.runtime_heartbeat(
            args.environment_id,
            str(state["runtime_instance_id"]),
            args.runtime_version,
            args.routine_triggered,
        )
        binding_id = heartbeat.get("id")
        if not binding_id:
            raise ControlPlaneError(502, "runtime heartbeat returned no binding id")
        state.update({
            "environment_id": args.environment_id,
            "runtime_binding_id": binding_id,
            "runtime_version": args.runtime_version,
        })
        write_private_json(runtime_path, state)
        messages = client.inbox(True, args.message_limit)
        signals = client.runtime_signals(str(binding_id), args.signal_limit)
        claim_result = None if args.no_claim else client.claim(args.lease_seconds)
        sanitized = None
        if claim_result is not None:
            claim_path = Path(args.claim_file).expanduser() if args.claim_file else default_claim_file(args.key_file)
            write_private_json(claim_path, claim_result)
            sanitized = sanitized_claim(claim_result, claim_path)
            claimed_id = claim_result.get("id") or claim_result.get("work_id")
            for signal in signals:
                if signal.get("work_item_id") == claimed_id and signal.get("id") is not None:
                    client.acknowledge_signal(int(signal["id"]))
        return {
            "runtime": {
                "binding_id": binding_id,
                "environment_id": args.environment_id,
                "status": heartbeat.get("status"),
                "runtime_file": str(runtime_path),
            },
            "messages": messages,
            "signals": signals,
            "claim": sanitized,
        }
    if args.command == "work-create":
        return sanitized_work_item(client.create_work_item(json_file(args.json_file)))
    if args.command == "claim":
        result = client.claim(args.lease_seconds)
        if result is None:
            return None
        claim_path = Path(args.claim_file).expanduser() if args.claim_file else default_claim_file(args.key_file)
        write_private_json(claim_path, result)
        return sanitized_claim(result, claim_path)
    if args.command == "claim-info":
        return claim_info(json_file(args.claim_file))
    if args.command == "heartbeat":
        work_item_id, lease_token, lease_version, claim_path = lease_fields(args)
        result = client.heartbeat(
            work_item_id,
            lease_token,
            lease_version,
            args.extend_seconds,
        )
        if claim_path is not None:
            claim = json_file(str(claim_path))
            if isinstance(result, dict):
                claim.update({key: value for key, value in result.items() if key != "lease_token"})
            write_private_json(claim_path, claim)
        return sanitized_claim(result, claim_path) if isinstance(result, dict) else result
    if args.command == "complete":
        work_item_id, lease_token, lease_version, _ = lease_fields(args)
        return client.complete(
            work_item_id,
            lease_token,
            lease_version,
            json_file(args.json_file),
        )
    if args.command == "fail":
        work_item_id, lease_token, lease_version, _ = lease_fields(args)
        return client.fail(
            work_item_id,
            lease_token,
            lease_version,
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
    if args.command == "artifact":
        return client.create_artifact(json_file(args.json_file))
    if args.command == "artifacts":
        return client.work_artifacts(args.work_item_id)
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

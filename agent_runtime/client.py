from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


DEFAULT_CONTROL_PLANE_URL = (
    "https://rldrudgtkxdrigbiqcsy.supabase.co/functions/v1/control-plane"
)


class ControlPlaneError(RuntimeError):
    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def load_agent_key(path: str | Path) -> str:
    key_path = Path(path).expanduser()
    if not key_path.is_file():
        raise ControlPlaneError(2, f"agent key file not found: {key_path}")

    if os.name == "posix":
        mode = stat.S_IMODE(key_path.stat().st_mode)
        if mode & 0o077:
            raise ControlPlaneError(
                2,
                f"agent key file permissions must be 0600: {key_path}",
            )

    key = key_path.read_text(encoding="utf-8").strip()
    if not key.startswith("asi.") or len(key) < 72:
        raise ControlPlaneError(2, "agent key file does not contain a valid asi.* key")
    return key


class ControlPlaneClient:
    def __init__(
        self,
        agent_key: str,
        base_url: str = DEFAULT_CONTROL_PLANE_URL,
        timeout: float = 30,
        opener: Callable[..., Any] = urlopen,
    ) -> None:
        normalized = base_url.rstrip("/")
        if not (
            normalized.startswith("https://")
            or normalized.startswith("http://127.0.0.1")
            or normalized.startswith("http://localhost")
        ):
            raise ControlPlaneError(2, "control-plane URL must use HTTPS")
        if not agent_key.startswith("asi."):
            raise ControlPlaneError(2, "invalid agent key")
        self._agent_key = agent_key
        self._base_url = normalized
        self._timeout = timeout
        self._opener = opener

    def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(
            f"{self._base_url}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {self._agent_key}",
                **({"Content-Type": "application/json"} if data is not None else {}),
            },
        )
        try:
            with self._opener(request, timeout=self._timeout) as response:
                body = response.read()
        except HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw)
                detail = parsed.get("detail", "control-plane request failed")
            except (json.JSONDecodeError, AttributeError):
                detail = "control-plane request failed"
            raise ControlPlaneError(exc.code, str(detail)) from exc
        except (URLError, TimeoutError) as exc:
            raise ControlPlaneError(503, "control plane is unavailable") from exc

        if not body:
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise ControlPlaneError(502, "control plane returned invalid JSON") from exc

    def me(self) -> dict[str, Any]:
        return self._request("GET", "/v1/me")

    def inbox(self, unread_only: bool = True, limit: int = 100) -> list[dict[str, Any]]:
        query = urlencode({
            "unread_only": str(unread_only).lower(),
            "limit": limit,
        })
        return self._request("GET", f"/v1/messages/inbox?{query}")

    def runtime_heartbeat(
        self,
        environment_id: str,
        runtime_instance_id: str,
        runtime_version: str = "agent-runtime/0.5.0",
        routine_triggered: bool = False,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            "/v1/runtime/heartbeat",
            {
                "environment_id": environment_id,
                "runtime_instance_id": runtime_instance_id,
                "runtime_version": runtime_version,
                "routine_triggered": routine_triggered,
                "metadata": metadata or {},
            },
        )

    def runtime_signals(
        self,
        runtime_binding_id: str,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        query = urlencode({
            "runtime_binding_id": runtime_binding_id,
            "limit": limit,
        })
        return self._request("GET", f"/v1/runtime/signals?{query}")

    def acknowledge_signal(self, signal_id: int) -> dict[str, Any]:
        return self._request("POST", f"/v1/runtime/signals/{signal_id}/ack", {})

    def create_work_item(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request("POST", "/v1/work-items", payload)

    def claim(self, lease_seconds: int = 900) -> dict[str, Any] | None:
        return self._request(
            "POST", "/v1/work-items/claim", {"lease_seconds": lease_seconds}
        )

    def heartbeat(
        self,
        work_item_id: str,
        lease_token: str,
        lease_version: int,
        extend_seconds: int = 300,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            f"/v1/work-items/{quote(work_item_id)}/heartbeat",
            {
                "lease_token": lease_token,
                "lease_version": lease_version,
                "extend_seconds": extend_seconds,
            },
        )

    def complete(
        self,
        work_item_id: str,
        lease_token: str,
        lease_version: int,
        output: dict[str, Any],
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            f"/v1/work-items/{quote(work_item_id)}/complete",
            {
                "lease_token": lease_token,
                "lease_version": lease_version,
                "output": output,
            },
        )

    def fail(
        self,
        work_item_id: str,
        lease_token: str,
        lease_version: int,
        error: dict[str, Any],
        failure_class: str = "unknown",
        retryable: bool = True,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            f"/v1/work-items/{quote(work_item_id)}/fail",
            {
                "lease_token": lease_token,
                "lease_version": lease_version,
                "failure_class": failure_class,
                "error": error,
                "retryable": retryable,
            },
        )

    def message(
        self,
        to_agent: str,
        kind: str,
        body: dict[str, Any],
        work_item_id: str | None = None,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            "/v1/messages",
            {
                "to_agent": to_agent,
                "work_item_id": work_item_id,
                "kind": kind,
                "body": body,
            },
        )

    def request_approval(
        self,
        work_item_id: str,
        action_type: str,
        summary: str,
        payload: dict[str, Any],
        risk: str,
        expires_at: str | None = None,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            "/v1/approvals",
            {
                "work_item_id": work_item_id,
                "action_type": action_type,
                "summary": summary,
                "payload": payload,
                "risk": risk,
                "expires_at": expires_at,
            },
        )

    def create_artifact(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request("POST", "/v1/artifacts", payload)

    def work_artifacts(self, work_item_id: str) -> list[dict[str, Any]]:
        return self._request(
            "GET",
            f"/v1/work-items/{quote(work_item_id)}/artifacts",
        )

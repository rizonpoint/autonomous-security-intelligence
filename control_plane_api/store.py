from datetime import datetime, timezone
from typing import Any
from uuid import UUID

import httpx

from .config import Settings
from .security import parse_agent_key, verify_agent_secret


class StoreError(RuntimeError):
    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class SupabaseStore:
    def __init__(self, base_url: str, service_role_key: str, timeout: float = 15):
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout,
            headers={
                "apikey": service_role_key,
                "Authorization": f"Bearer {service_role_key}",
                "Accept": "application/json",
            },
        )

    @classmethod
    def from_settings(cls, settings: Settings) -> "SupabaseStore":
        return cls(
            str(settings.supabase_url),
            settings.supabase_service_role_key.get_secret_value(),
            settings.control_plane_request_timeout_seconds,
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | None = None,
        json: Any = None,
        prefer: str | None = None,
    ) -> Any:
        headers = {"Prefer": prefer} if prefer else None
        try:
            response = await self._client.request(
                method, path, params=params, json=json, headers=headers
            )
        except httpx.TimeoutException as exc:
            raise StoreError(504, "control-plane database timed out") from exc
        except httpx.HTTPError as exc:
            raise StoreError(502, "control-plane database is unavailable") from exc

        if response.status_code >= 400:
            try:
                payload = response.json()
                message = payload.get("message") or payload.get("error_description") or str(payload)
                code = payload.get("code")
            except ValueError:
                message, code = response.text, None
            status = 409 if code in {"23505", "P0001"} else response.status_code
            raise StoreError(status, message or "database request failed")
        if not response.content:
            return None
        return response.json()

    @staticmethod
    def _one(payload: Any) -> dict[str, Any] | None:
        if payload is None:
            return None
        if isinstance(payload, list):
            return payload[0] if payload else None
        return payload

    async def authenticate_agent(self, plaintext_key: str) -> dict[str, Any]:
        try:
            credential_id, secret = parse_agent_key(plaintext_key)
        except ValueError as exc:
            raise StoreError(401, "invalid agent credential") from exc

        credentials = await self._request(
            "GET",
            "/rest/v1/agent_credentials",
            params={
                "id": f"eq.{credential_id}",
                "select": "id,agent_id,key_hash,expires_at,revoked_at",
                "limit": "1",
            },
        )
        credential = self._one(credentials)
        if not credential or credential["revoked_at"] is not None:
            raise StoreError(401, "invalid agent credential")
        if not verify_agent_secret(secret, credential["key_hash"]):
            raise StoreError(401, "invalid agent credential")
        if credential["expires_at"]:
            expiry = datetime.fromisoformat(credential["expires_at"].replace("Z", "+00:00"))
            if expiry <= datetime.now(timezone.utc):
                raise StoreError(401, "agent credential has expired")

        agents = await self._request(
            "GET",
            "/rest/v1/agents",
            params={
                "id": f"eq.{credential['agent_id']}",
                "select": "id,name,role,authority_level,capabilities,status,max_concurrency",
                "limit": "1",
            },
        )
        agent = self._one(agents)
        if not agent or agent["status"] == "disabled":
            raise StoreError(403, "agent is disabled")

        now = datetime.now(timezone.utc).isoformat()
        await self._request(
            "PATCH",
            "/rest/v1/agent_credentials",
            params={"id": f"eq.{credential_id}"},
            json={"last_used_at": now},
        )
        await self._request(
            "PATCH",
            "/rest/v1/agents",
            params={"id": f"eq.{agent['id']}"},
            json={"last_seen_at": now},
        )
        return agent

    async def rpc(self, name: str, payload: dict[str, Any]) -> Any:
        return await self._request("POST", f"/rest/v1/rpc/{name}", json=payload)

    async def register_agent(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self.rpc("register_agent", payload)
        return self._one(result) or {}

    async def create_work_item(self, agent_id: UUID, payload: dict[str, Any]) -> dict[str, Any]:
        body = {**payload, "requested_by": str(agent_id)}
        result = await self._request(
            "POST", "/rest/v1/work_items", json=body, prefer="return=representation"
        )
        return self._one(result) or {}

    async def get_work_item(self, work_item_id: UUID) -> dict[str, Any] | None:
        result = await self._request(
            "GET",
            "/rest/v1/work_items",
            params={"id": f"eq.{work_item_id}", "select": "*", "limit": "1"},
        )
        return self._one(result)

    async def claim_work(self, agent_id: UUID, lease_seconds: int) -> dict[str, Any] | None:
        result = await self.rpc(
            "claim_next_work_item",
            {"p_agent_id": str(agent_id), "p_lease_seconds": lease_seconds},
        )
        return self._one(result)

    async def heartbeat(
        self, work_item_id: UUID, agent_id: UUID, lease_token: UUID,
        lease_version: int, extend_seconds: int
    ) -> Any:
        return await self.rpc(
            "heartbeat_work_attempt",
            {
                "p_work_item_id": str(work_item_id),
                "p_agent_id": str(agent_id),
                "p_lease_token": str(lease_token),
                "p_lease_version": lease_version,
                "p_extend_seconds": extend_seconds,
            },
        )

    async def complete_work(
        self, work_item_id: UUID, agent_id: UUID, lease_token: UUID,
        lease_version: int, output: dict[str, Any]
    ) -> dict[str, Any]:
        result = await self.rpc(
            "complete_work_attempt",
            {
                "p_work_item_id": str(work_item_id),
                "p_agent_id": str(agent_id),
                "p_lease_token": str(lease_token),
                "p_lease_version": lease_version,
                "p_output": output,
            },
        )
        return self._one(result) or {}

    async def fail_work(
        self, work_item_id: UUID, agent_id: UUID, lease_token: UUID,
        lease_version: int, failure_class: str, error: dict[str, Any], retryable: bool
    ) -> dict[str, Any]:
        result = await self.rpc(
            "fail_work_attempt",
            {
                "p_work_item_id": str(work_item_id),
                "p_agent_id": str(agent_id),
                "p_lease_token": str(lease_token),
                "p_lease_version": lease_version,
                "p_failure_class": failure_class,
                "p_error": error,
                "p_retryable": retryable,
            },
        )
        return self._one(result) or {}

    async def send_message(self, agent_id: UUID, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST",
            "/rest/v1/messages",
            json={**payload, "from_agent": str(agent_id)},
            prefer="return=representation",
        )
        return self._one(result) or {}

    async def inbox(self, agent_id: UUID, unread_only: bool, limit: int) -> list[dict[str, Any]]:
        params = {
            "to_agent": f"eq.{agent_id}",
            "select": "*",
            "order": "created_at.asc",
            "limit": str(limit),
        }
        if unread_only:
            params["read_at"] = "is.null"
        return await self._request("GET", "/rest/v1/messages", params=params) or []

    async def get_state(self, namespace: str, key: str) -> dict[str, Any] | None:
        result = await self._request(
            "GET",
            "/rest/v1/shared_state",
            params={
                "namespace": f"eq.{namespace}",
                "key": f"eq.{key}",
                "select": "*",
                "limit": "1",
            },
        )
        return self._one(result)

    async def write_state(
        self, agent_id: UUID, namespace: str, key: str,
        value: dict[str, Any], expected_version: int
    ) -> dict[str, Any]:
        result = await self.rpc(
            "compare_and_swap_shared_state",
            {
                "p_namespace": namespace,
                "p_key": key,
                "p_value": value,
                "p_expected_version": expected_version,
                "p_updated_by": str(agent_id),
            },
        )
        return self._one(result) or {}

    async def request_approval(self, agent_id: UUID, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST",
            "/rest/v1/approvals",
            json={**payload, "requested_by": str(agent_id)},
            prefer="return=representation",
        )
        return self._one(result) or {}


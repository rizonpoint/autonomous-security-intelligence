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
                "select": "id,workspace_id,agent_id,key_hash,expires_at,revoked_at",
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
                "workspace_id": f"eq.{credential['workspace_id']}",
                "select": "id,workspace_id,name,role,authority_level,capabilities,status,max_concurrency",
                "limit": "1",
            },
        )
        agent = self._one(agents)
        if not agent or agent["status"] == "disabled":
            raise StoreError(403, "agent is disabled")

        workspaces = await self._request(
            "GET",
            "/rest/v1/workspaces",
            params={
                "id": f"eq.{agent['workspace_id']}",
                "select": "id,organization_id,status",
                "limit": "1",
            },
        )
        workspace = self._one(workspaces)
        if not workspace or workspace["status"] != "active":
            raise StoreError(403, "agent workspace is unavailable")

        organizations = await self._request(
            "GET",
            "/rest/v1/organizations",
            params={
                "id": f"eq.{workspace['organization_id']}",
                "select": "id,status",
                "limit": "1",
            },
        )
        organization = self._one(organizations)
        if not organization or organization["status"] != "active":
            raise StoreError(403, "agent organization is unavailable")
        agent["organization_id"] = organization["id"]

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

    async def create_organization(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/organizations", json=payload, prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_organizations(self) -> list[dict[str, Any]]:
        return await self._request(
            "GET",
            "/rest/v1/organizations",
            params={"select": "*", "order": "created_at.asc"},
        ) or []

    async def create_workspace(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/workspaces", json=payload, prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_workspaces(self, organization_id: UUID | None) -> list[dict[str, Any]]:
        params = {"select": "*", "order": "created_at.asc"}
        if organization_id is not None:
            params["organization_id"] = f"eq.{organization_id}"
        return await self._request("GET", "/rest/v1/workspaces", params=params) or []

    async def create_venture(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/ventures", json=payload, prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_ventures(self, organization_id: UUID | None) -> list[dict[str, Any]]:
        params = {"select": "*", "order": "created_at.asc"}
        if organization_id is not None:
            params["organization_id"] = f"eq.{organization_id}"
        return await self._request("GET", "/rest/v1/ventures", params=params) or []

    async def list_venture_blueprints(self) -> list[dict[str, Any]]:
        return await self._request(
            "GET",
            "/rest/v1/venture_blueprints",
            params={"select": "*,venture_blueprint_versions(*)", "order": "created_at.asc"},
        ) or []

    async def create_model_provider(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/model_providers", json=payload,
            prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_model_providers(self) -> list[dict[str, Any]]:
        return await self._request(
            "GET", "/rest/v1/model_providers",
            params={"select": "*", "order": "created_at.asc"},
        ) or []

    async def create_model_deployment(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/model_deployments", json=payload,
            prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_model_deployments(self, organization_id: UUID | None) -> list[dict[str, Any]]:
        params = {"select": "*", "order": "created_at.asc"}
        if organization_id is not None:
            params["or"] = f"(organization_id.is.null,organization_id.eq.{organization_id})"
        return await self._request("GET", "/rest/v1/model_deployments", params=params) or []

    async def create_task_profile(self, payload: dict[str, Any]) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/task_profiles", json=payload,
            prefer="return=representation"
        )
        return self._one(result) or {}

    async def list_task_profiles(self, organization_id: UUID) -> list[dict[str, Any]]:
        return await self._request(
            "GET", "/rest/v1/task_profiles",
            params={
                "organization_id": f"eq.{organization_id}",
                "select": "*",
                "order": "created_at.asc",
            },
        ) or []

    async def create_worker_environment(self, payload: dict[str, Any]) -> dict[str, Any]:
        workspace_id = payload["workspace_id"]
        workspace = self._one(await self._request(
            "GET", "/rest/v1/workspaces",
            params={
                "id": f"eq.{workspace_id}",
                "select": "id,organization_id,venture_id",
                "limit": "1",
            },
        ))
        if not workspace:
            raise StoreError(404, "workspace not found")
        body = {
            **payload,
            "organization_id": workspace["organization_id"],
            "venture_id": workspace["venture_id"],
        }
        result = await self._request(
            "POST", "/rest/v1/worker_environments", json=body,
            prefer="return=representation",
        )
        return self._one(result) or {}

    async def list_worker_environments(
        self, workspace_id: UUID | None
    ) -> list[dict[str, Any]]:
        params = {"select": "*", "order": "created_at.asc"}
        if workspace_id is not None:
            params["workspace_id"] = f"eq.{workspace_id}"
        return await self._request(
            "GET", "/rest/v1/worker_environments", params=params
        ) or []

    async def runtime_heartbeat(
        self, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        result = await self.rpc("heartbeat_agent_runtime", {
            "p_agent_id": str(agent_id),
            "p_environment_id": payload["environment_id"],
            "p_runtime_instance_id": payload["runtime_instance_id"],
            "p_runtime_version": payload.get("runtime_version"),
            "p_routine_triggered": payload.get("routine_triggered", False),
            "p_metadata": payload.get("metadata", {}),
        })
        return self._one(result) or {}

    async def pull_runtime_signals(
        self, binding_id: UUID, agent_id: UUID, limit: int
    ) -> list[dict[str, Any]]:
        return await self.rpc("pull_dispatch_signals", {
            "p_runtime_binding_id": str(binding_id),
            "p_agent_id": str(agent_id),
            "p_limit": limit,
        }) or []

    async def acknowledge_runtime_signal(
        self, signal_id: int, agent_id: UUID
    ) -> dict[str, Any]:
        result = await self.rpc("acknowledge_dispatch_signal", {
            "p_signal_id": signal_id,
            "p_agent_id": str(agent_id),
        })
        return self._one(result) or {}

    async def create_artifact(
        self, workspace_id: UUID, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        result = await self._request(
            "POST", "/rest/v1/artifacts",
            json={
                **payload,
                "workspace_id": str(workspace_id),
                "created_by": str(agent_id),
            },
            prefer="return=representation",
        )
        return self._one(result) or {}

    async def list_artifacts(
        self, workspace_id: UUID, work_item_id: UUID
    ) -> list[dict[str, Any]]:
        return await self._request(
            "GET", "/rest/v1/artifacts",
            params={
                "workspace_id": f"eq.{workspace_id}",
                "work_item_id": f"eq.{work_item_id}",
                "select": "*",
                "order": "artifact_version.desc,created_at.desc",
            },
        ) or []

    async def create_work_item(
        self, workspace_id: UUID, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        body = {
            **payload,
            "workspace_id": str(workspace_id),
            "requested_by": str(agent_id),
        }
        result = await self._request(
            "POST", "/rest/v1/work_items", json=body, prefer="return=representation"
        )
        return self._one(result) or {}

    async def get_work_item(
        self, workspace_id: UUID, work_item_id: UUID
    ) -> dict[str, Any] | None:
        result = await self._request(
            "GET",
            "/rest/v1/work_items",
            params={
                "workspace_id": f"eq.{workspace_id}",
                "id": f"eq.{work_item_id}",
                "select": "*",
                "limit": "1",
            },
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

    async def send_message(
        self, workspace_id: UUID, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        result = await self._request(
            "POST",
            "/rest/v1/messages",
            json={
                **payload,
                "workspace_id": str(workspace_id),
                "from_agent": str(agent_id),
            },
            prefer="return=representation",
        )
        return self._one(result) or {}

    async def inbox(
        self, workspace_id: UUID, agent_id: UUID, unread_only: bool, limit: int
    ) -> list[dict[str, Any]]:
        params = {
            "workspace_id": f"eq.{workspace_id}",
            "to_agent": f"eq.{agent_id}",
            "select": "*",
            "order": "created_at.asc",
            "limit": str(limit),
        }
        if unread_only:
            params["read_at"] = "is.null"
        return await self._request("GET", "/rest/v1/messages", params=params) or []

    async def get_state(
        self, workspace_id: UUID, namespace: str, key: str
    ) -> dict[str, Any] | None:
        result = await self._request(
            "GET",
            "/rest/v1/shared_state",
            params={
                "workspace_id": f"eq.{workspace_id}",
                "namespace": f"eq.{namespace}",
                "key": f"eq.{key}",
                "select": "*",
                "limit": "1",
            },
        )
        return self._one(result)

    async def write_state(
        self, workspace_id: UUID, agent_id: UUID, namespace: str, key: str,
        value: dict[str, Any], expected_version: int
    ) -> dict[str, Any]:
        result = await self.rpc(
            "compare_and_swap_shared_state",
            {
                "p_workspace_id": str(workspace_id),
                "p_namespace": namespace,
                "p_key": key,
                "p_value": value,
                "p_expected_version": expected_version,
                "p_updated_by": str(agent_id),
            },
        )
        return self._one(result) or {}

    async def request_approval(
        self, workspace_id: UUID, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        result = await self._request(
            "POST",
            "/rest/v1/approvals",
            json={
                **payload,
                "workspace_id": str(workspace_id),
                "requested_by": str(agent_id),
            },
            prefer="return=representation",
        )
        return self._one(result) or {}

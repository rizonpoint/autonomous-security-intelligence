from typing import Any
from uuid import UUID, uuid4

from httpx import ASGITransport, AsyncClient

from control_plane_api.dependencies import current_agent, get_store, require_admin
from control_plane_api.main import app


ORGANIZATION_ID = uuid4()
WORKSPACE_ID = uuid4()
AGENT_ID = uuid4()


def agent_identity() -> dict[str, Any]:
    return {
        "id": str(AGENT_ID),
        "workspace_id": str(WORKSPACE_ID),
        "organization_id": str(ORGANIZATION_ID),
        "name": "Market Intelligence",
        "role": "Monitor markets, accounts, and actionable signals",
        "authority_level": 2,
        "capabilities": ["market_research", "signal_detection"],
        "status": "idle",
        "max_concurrency": 1,
    }


class FakeStore:
    def __init__(self) -> None:
        self.registration_payload: dict[str, Any] | None = None
        self.created_work: dict[str, Any] | None = None
        self.organizations: list[dict[str, Any]] = []
        self.workspaces: list[dict[str, Any]] = []

    async def register_agent(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.registration_payload = payload
        created = agent_identity()
        created.update(
            workspace_id=payload["p_workspace_id"],
            name=payload["p_name"],
            role=payload["p_role"],
            authority_level=payload["p_authority_level"],
            capabilities=payload["p_capabilities"],
            max_concurrency=payload["p_max_concurrency"],
        )
        return {"agent": created, "credential_id": payload["p_credential_id"]}

    async def create_organization(self, payload: dict[str, Any]) -> dict[str, Any]:
        organization = {
            "id": str(ORGANIZATION_ID),
            "status": "active",
            **payload,
        }
        self.organizations.append(organization)
        return organization

    async def list_organizations(self) -> list[dict[str, Any]]:
        return self.organizations

    async def create_workspace(self, payload: dict[str, Any]) -> dict[str, Any]:
        workspace = {
            "id": str(WORKSPACE_ID),
            "status": "active",
            **payload,
        }
        self.workspaces.append(workspace)
        return workspace

    async def list_workspaces(
        self, organization_id: UUID | None
    ) -> list[dict[str, Any]]:
        if organization_id is None:
            return self.workspaces
        return [
            workspace for workspace in self.workspaces
            if workspace["organization_id"] == str(organization_id)
        ]

    async def create_work_item(
        self, workspace_id: UUID, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        self.created_work = {
            **payload,
            "workspace_id": str(workspace_id),
            "requested_by": str(agent_id),
        }
        return {"id": str(uuid4()), **self.created_work, "status": "queued"}

    async def claim_work(self, agent_id: UUID, lease_seconds: int) -> dict[str, Any]:
        return {
            "id": str(uuid4()),
            "assigned_to": str(agent_id),
            "status": "claimed",
            "lease_seconds": lease_seconds,
        }


def make_client() -> tuple[AsyncClient, FakeStore]:
    store = FakeStore()
    app.dependency_overrides[get_store] = lambda: store
    app.dependency_overrides[current_agent] = agent_identity
    app.dependency_overrides[require_admin] = lambda: None
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test"), store


def clear_overrides() -> None:
    app.dependency_overrides.clear()


async def test_health_and_identity() -> None:
    client, _ = make_client()
    try:
        assert (await client.get("/health")).json() == {"status": "ok"}
        response = await client.get("/v1/me")
        assert response.status_code == 200
        assert response.json()["name"] == "Market Intelligence"
        assert response.json()["workspace_id"] == str(WORKSPACE_ID)
    finally:
        await client.aclose()
        clear_overrides()


async def test_admin_creates_hashed_agent_credential() -> None:
    client, store = make_client()
    try:
        response = await client.post(
            "/v1/admin/agents",
            json={
                "workspace_id": str(WORKSPACE_ID),
                "name": "Researcher",
                "role": "Research target accounts",
                "capabilities": ["company_research"],
            },
        )
        assert response.status_code == 201, response.text
        body = response.json()
        assert body["api_key"].startswith("asi.")
        assert store.registration_payload is not None
        assert store.registration_payload["p_workspace_id"] == str(WORKSPACE_ID)
        assert store.registration_payload["p_key_hash"].startswith("scrypt$")
        assert body["api_key"] not in store.registration_payload["p_key_hash"]
    finally:
        await client.aclose()
        clear_overrides()


async def test_create_and_claim_work() -> None:
    client, store = make_client()
    try:
        created = await client.post(
            "/v1/work-items",
            json={
                "work_type": "job_search",
                "title": "Find ten AI Solutions roles",
                "required_capabilities": ["job_search"],
                "input": {"resume_variant": "best_fit"},
            },
        )
        assert created.status_code == 201, created.text
        assert store.created_work is not None
        assert store.created_work["workspace_id"] == str(WORKSPACE_ID)
        assert store.created_work["requested_by"] == str(AGENT_ID)

        claimed = await client.post("/v1/work-items/claim", json={"lease_seconds": 120})
        assert claimed.status_code == 200, claimed.text
        assert claimed.json()["assigned_to"] == str(AGENT_ID)
    finally:
        await client.aclose()
        clear_overrides()


async def test_admin_creates_business_organization_and_workspace() -> None:
    client, store = make_client()
    try:
        organization = await client.post(
            "/v1/admin/organizations",
            json={"slug": "autonomous-companies", "name": "Autonomous Companies"},
        )
        assert organization.status_code == 201, organization.text
        assert organization.json()["id"] == str(ORGANIZATION_ID)

        workspace = await client.post(
            "/v1/admin/workspaces",
            json={
                "organization_id": str(ORGANIZATION_ID),
                "slug": "cybersecurity-intelligence-studio",
                "name": "Autonomous Cybersecurity Intelligence Studio",
                "kind": "business",
                "purpose": "Operate the Account Signal Intelligence business.",
            },
        )
        assert workspace.status_code == 201, workspace.text
        assert workspace.json()["organization_id"] == str(ORGANIZATION_ID)
        assert len(store.workspaces) == 1
    finally:
        await client.aclose()
        clear_overrides()

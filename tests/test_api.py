from typing import Any
from uuid import UUID, uuid4

from httpx import ASGITransport, AsyncClient

from control_plane_api.dependencies import current_agent, get_store, require_admin
from control_plane_api.main import app


AGENT_ID = uuid4()


def agent_identity() -> dict[str, Any]:
    return {
        "id": str(AGENT_ID),
        "name": "Job Scout",
        "role": "Find and rank job opportunities",
        "authority_level": 1,
        "capabilities": ["job_search", "rank_role"],
        "status": "idle",
        "max_concurrency": 1,
    }


class FakeStore:
    def __init__(self) -> None:
        self.registration_payload: dict[str, Any] | None = None
        self.created_work: dict[str, Any] | None = None

    async def register_agent(self, payload: dict[str, Any]) -> dict[str, Any]:
        self.registration_payload = payload
        created = agent_identity()
        created.update(
            name=payload["p_name"],
            role=payload["p_role"],
            authority_level=payload["p_authority_level"],
            capabilities=payload["p_capabilities"],
            max_concurrency=payload["p_max_concurrency"],
        )
        return {"agent": created, "credential_id": payload["p_credential_id"]}

    async def create_work_item(self, agent_id: UUID, payload: dict[str, Any]) -> dict[str, Any]:
        self.created_work = {**payload, "requested_by": str(agent_id)}
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
        assert response.json()["name"] == "Job Scout"
    finally:
        await client.aclose()
        clear_overrides()


async def test_admin_creates_hashed_agent_credential() -> None:
    client, store = make_client()
    try:
        response = await client.post(
            "/v1/admin/agents",
            json={
                "name": "Researcher",
                "role": "Research target accounts",
                "capabilities": ["company_research"],
            },
        )
        assert response.status_code == 201, response.text
        body = response.json()
        assert body["api_key"].startswith("asi.")
        assert store.registration_payload is not None
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
        assert store.created_work["requested_by"] == str(AGENT_ID)

        claimed = await client.post("/v1/work-items/claim", json={"lease_seconds": 120})
        assert claimed.status_code == 200, claimed.text
        assert claimed.json()["assigned_to"] == str(AGENT_ID)
    finally:
        await client.aclose()
        clear_overrides()

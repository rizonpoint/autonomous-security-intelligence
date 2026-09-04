from typing import Any
from uuid import UUID, uuid4

from httpx import ASGITransport, AsyncClient

from control_plane_api.dependencies import current_agent, get_store, require_admin
from control_plane_api.main import app


ORGANIZATION_ID = uuid4()
WORKSPACE_ID = uuid4()
AGENT_ID = uuid4()
VENTURE_ID = uuid4()
PROVIDER_ID = uuid4()
DEPLOYMENT_ID = uuid4()
TASK_PROFILE_ID = uuid4()
ENVIRONMENT_ID = uuid4()
RUNTIME_BINDING_ID = uuid4()


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
        self.ventures: list[dict[str, Any]] = []
        self.model_providers: list[dict[str, Any]] = []
        self.model_deployments: list[dict[str, Any]] = []
        self.task_profiles: list[dict[str, Any]] = []
        self.worker_environments: list[dict[str, Any]] = []

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

    async def create_venture(self, payload: dict[str, Any]) -> dict[str, Any]:
        venture = {"id": str(VENTURE_ID), "status": "active", **payload}
        self.ventures.append(venture)
        return venture

    async def list_ventures(self, organization_id: UUID | None) -> list[dict[str, Any]]:
        if organization_id is None:
            return self.ventures
        return [v for v in self.ventures if v["organization_id"] == str(organization_id)]

    async def list_venture_blueprints(self) -> list[dict[str, Any]]:
        return [{"slug": "lean-b2b-service", "status": "active"}]

    async def create_model_provider(self, payload: dict[str, Any]) -> dict[str, Any]:
        provider = {"id": str(PROVIDER_ID), "status": "active", **payload}
        self.model_providers.append(provider)
        return provider

    async def list_model_providers(self) -> list[dict[str, Any]]:
        return self.model_providers

    async def create_model_deployment(self, payload: dict[str, Any]) -> dict[str, Any]:
        deployment = {"id": str(DEPLOYMENT_ID), "status": "active", **payload}
        self.model_deployments.append(deployment)
        return deployment

    async def list_model_deployments(self, organization_id: UUID | None) -> list[dict[str, Any]]:
        return self.model_deployments

    async def create_task_profile(self, payload: dict[str, Any]) -> dict[str, Any]:
        profile = {
            "id": str(TASK_PROFILE_ID),
            "status": "active",
            "risk_tier": "low",
            "max_turns": 8,
            "max_tool_calls": 20,
            "allowed_provider_slugs": [],
            "allowed_model_keys": [],
            "data_classification": "internal",
            **payload,
        }
        self.task_profiles.append(profile)
        return profile

    async def list_task_profiles(self, organization_id: UUID) -> list[dict[str, Any]]:
        return self.task_profiles

    async def create_worker_environment(self, payload: dict[str, Any]) -> dict[str, Any]:
        environment = {
            "id": str(ENVIRONMENT_ID),
            "organization_id": str(ORGANIZATION_ID),
            "venture_id": str(VENTURE_ID),
            "attestation_state": "declared",
            "status": "active",
            **payload,
        }
        self.worker_environments.append(environment)
        return environment

    async def list_worker_environments(
        self, workspace_id: UUID | None
    ) -> list[dict[str, Any]]:
        return self.worker_environments

    async def runtime_heartbeat(
        self, agent_id: UUID, payload: dict[str, Any]
    ) -> dict[str, Any]:
        return {
            "id": str(RUNTIME_BINDING_ID),
            "agent_id": str(agent_id),
            "status": "online",
            **payload,
        }

    async def pull_runtime_signals(
        self, binding_id: UUID, agent_id: UUID, limit: int
    ) -> list[dict[str, Any]]:
        return [{"id": 7, "runtime_binding_id": str(binding_id), "agent_id": str(agent_id)}]

    async def acknowledge_runtime_signal(
        self, signal_id: int, agent_id: UUID
    ) -> dict[str, Any]:
        return {"id": signal_id, "agent_id": str(agent_id), "status": "acknowledged"}

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


async def test_worker_without_delegation_authority_cannot_create_work() -> None:
    client, store = make_client()
    worker = agent_identity()
    worker["authority_level"] = 1
    worker["capabilities"] = ["market_research"]
    app.dependency_overrides[current_agent] = lambda: worker
    try:
        response = await client.post(
            "/v1/work-items",
            json={"work_type": "review", "title": "Create unauthorized work"},
        )
        assert response.status_code == 403
        assert response.json() == {"detail": "agent lacks delegation authority"}
        assert store.created_work is None
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


async def test_admin_creates_venture_and_model_routing_catalog() -> None:
    client, store = make_client()
    try:
        venture = await client.post(
            "/v1/admin/ventures",
            json={
                "organization_id": str(ORGANIZATION_ID),
                "slug": "cybersecurity-studio",
                "name": "Cybersecurity Studio",
                "venture_type": "proof_of_concept",
                "stage": "validation",
            },
        )
        assert venture.status_code == 201, venture.text
        assert venture.json()["id"] == str(VENTURE_ID)

        provider = await client.post(
            "/v1/admin/model-providers",
            json={"slug": "provider-a", "name": "Provider A", "api_family": "responses"},
        )
        assert provider.status_code == 201, provider.text

        deployment = await client.post(
            "/v1/admin/model-deployments",
            json={
                "provider_id": str(PROVIDER_ID),
                "model_key": "model-a",
                "display_name": "Model A",
                "capabilities": ["research"],
                "input_usd_per_million": 1.0,
                "output_usd_per_million": 2.0,
            },
        )
        assert deployment.status_code == 201, deployment.text

        profile = await client.post(
            "/v1/admin/task-profiles",
            json={
                "organization_id": str(ORGANIZATION_ID),
                "venture_id": str(VENTURE_ID),
                "slug": "evidence-research",
                "name": "Evidence Research",
                "required_capabilities": ["research"],
                "minimum_quality_score": 0.85,
                "max_cost_usd": 0.50,
            },
        )
        assert profile.status_code == 201, profile.text
        assert len(store.ventures) == 1
        assert len(store.model_providers) == 1
        assert len(store.model_deployments) == 1
        assert len(store.task_profiles) == 1
    finally:
        await client.aclose()
        clear_overrides()


async def test_admin_declares_trust_zone_and_worker_reports_liveness() -> None:
    client, store = make_client()
    try:
        environment = await client.post(
            "/v1/admin/worker-environments",
            json={
                "workspace_id": str(WORKSPACE_ID),
                "slug": "shared-grok",
                "name": "Shared Grok Computer",
                "provider": "xai",
                "runtime_type": "grok_bot",
                "isolation_level": "shared_account",
            },
        )
        assert environment.status_code == 201, environment.text
        assert environment.json()["isolation_level"] == "shared_account"

        heartbeat = await client.post(
            "/v1/runtime/heartbeat",
            json={
                "environment_id": str(ENVIRONMENT_ID),
                "runtime_instance_id": str(uuid4()),
                "runtime_version": "agent-runtime/0.5.0",
                "routine_triggered": True,
            },
        )
        assert heartbeat.status_code == 200, heartbeat.text
        assert heartbeat.json()["status"] == "online"

        signals = await client.get(
            "/v1/runtime/signals",
            params={"runtime_binding_id": str(RUNTIME_BINDING_ID)},
        )
        assert signals.status_code == 200, signals.text
        assert signals.json()[0]["id"] == 7

        ack = await client.post("/v1/runtime/signals/7/ack")
        assert ack.status_code == 200, ack.text
        assert ack.json()["status"] == "acknowledged"
        assert len(store.worker_environments) == 1
    finally:
        await client.aclose()
        clear_overrides()

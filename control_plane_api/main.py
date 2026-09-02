from contextlib import asynccontextmanager
from typing import Any
from uuid import UUID

from fastapi import FastAPI, HTTPException, Query, status

from .dependencies import Admin, Agent, Store, as_http_error, get_store
from .schemas import (
    AdminAgentCreate,
    AdminAgentCreated,
    AdminOrganizationCreate,
    AdminWorkspaceCreate,
    AgentIdentity,
    ApprovalCreate,
    ClaimRequest,
    CompleteRequest,
    FailRequest,
    HeartbeatRequest,
    MessageCreate,
    Organization,
    StateWrite,
    WorkItemCreate,
    Workspace,
)
from .security import issue_agent_key
from .store import StoreError


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    if get_store.cache_info().currsize:
        await get_store().close()


app = FastAPI(
    title="Autonomous Security Intelligence Control Plane",
    version="0.3.0",
    description="Provider-neutral coordination, authorization, and audit API for autonomous agents.",
    lifespan=lifespan,
)


def serialize(model: Any, *, exclude_none: bool = True) -> dict[str, Any]:
    return model.model_dump(mode="json", exclude_none=exclude_none)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/admin/agents", response_model=AdminAgentCreated, status_code=status.HTTP_201_CREATED)
async def create_agent(body: AdminAgentCreate, _: Admin, store: Store) -> AdminAgentCreated:
    issued = issue_agent_key()
    payload = serialize(body)
    payload.update(
        {
            "p_workspace_id": payload.pop("workspace_id"),
            "p_credential_id": str(issued.credential_id),
            "p_key_hash": issued.encoded_hash,
            "p_name": payload.pop("name"),
            "p_role": payload.pop("role"),
            "p_authority_level": payload.pop("authority_level"),
            "p_capabilities": payload.pop("capabilities"),
            "p_max_concurrency": payload.pop("max_concurrency"),
            "p_credential_label": payload.pop("credential_label"),
            "p_expires_at": payload.pop("expires_at", None),
            "p_metadata": payload.pop("metadata"),
        }
    )
    try:
        created = await store.register_agent(payload)
    except StoreError as exc:
        raise as_http_error(exc) from exc
    return AdminAgentCreated(
        agent=AgentIdentity.model_validate(created["agent"]),
        credential_id=issued.credential_id,
        api_key=issued.plaintext,
    )


@app.post(
    "/v1/admin/organizations",
    response_model=Organization,
    status_code=status.HTTP_201_CREATED,
)
async def create_organization(
    body: AdminOrganizationCreate, _: Admin, store: Store
) -> dict[str, Any]:
    try:
        return await store.create_organization(serialize(body))
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/admin/organizations", response_model=list[Organization])
async def list_organizations(_: Admin, store: Store) -> list[dict[str, Any]]:
    try:
        return await store.list_organizations()
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.post(
    "/v1/admin/workspaces",
    response_model=Workspace,
    status_code=status.HTTP_201_CREATED,
)
async def create_workspace(
    body: AdminWorkspaceCreate, _: Admin, store: Store
) -> dict[str, Any]:
    try:
        return await store.create_workspace(serialize(body))
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/admin/workspaces", response_model=list[Workspace])
async def list_workspaces(
    _: Admin,
    store: Store,
    organization_id: UUID | None = None,
) -> list[dict[str, Any]]:
    try:
        return await store.list_workspaces(organization_id)
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/me", response_model=AgentIdentity)
async def me(agent: Agent) -> dict[str, Any]:
    return agent


@app.post("/v1/work-items", status_code=status.HTTP_201_CREATED)
async def create_work_item(body: WorkItemCreate, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        return await store.create_work_item(
            UUID(agent["workspace_id"]), UUID(agent["id"]), serialize(body)
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/work-items/{work_item_id}")
async def get_work_item(work_item_id: UUID, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        item = await store.get_work_item(UUID(agent["workspace_id"]), work_item_id)
    except StoreError as exc:
        raise as_http_error(exc) from exc
    if not item:
        raise HTTPException(status_code=404, detail="work item not found")
    if str(agent["id"]) not in {item.get("requested_by"), item.get("assigned_to")}:
        raise HTTPException(status_code=403, detail="agent is not a participant in this work item")
    return item


@app.post("/v1/work-items/claim")
async def claim_work(body: ClaimRequest, agent: Agent, store: Store) -> dict[str, Any] | None:
    try:
        return await store.claim_work(UUID(agent["id"]), body.lease_seconds)
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.post("/v1/work-items/{work_item_id}/heartbeat")
async def heartbeat(work_item_id: UUID, body: HeartbeatRequest, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        expires_at = await store.heartbeat(
            work_item_id, UUID(agent["id"]), body.lease_token,
            body.lease_version, body.extend_seconds
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc
    return {"lease_expires_at": expires_at}


@app.post("/v1/work-items/{work_item_id}/complete")
async def complete_work(work_item_id: UUID, body: CompleteRequest, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        return await store.complete_work(
            work_item_id, UUID(agent["id"]), body.lease_token,
            body.lease_version, body.output
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.post("/v1/work-items/{work_item_id}/fail")
async def fail_work(work_item_id: UUID, body: FailRequest, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        return await store.fail_work(
            work_item_id, UUID(agent["id"]), body.lease_token,
            body.lease_version, body.failure_class, body.error, body.retryable
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.post("/v1/messages", status_code=status.HTTP_201_CREATED)
async def send_message(body: MessageCreate, agent: Agent, store: Store) -> dict[str, Any]:
    if body.kind == "system":
        raise HTTPException(status_code=403, detail="agents cannot create system messages")
    if body.to_agent is None:
        raise HTTPException(status_code=422, detail="to_agent is required")
    try:
        return await store.send_message(
            UUID(agent["workspace_id"]), UUID(agent["id"]), serialize(body)
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/messages/inbox")
async def inbox(
    agent: Agent,
    store: Store,
    unread_only: bool = True,
    limit: int = Query(default=100, ge=1, le=500),
) -> list[dict[str, Any]]:
    try:
        return await store.inbox(
            UUID(agent["workspace_id"]), UUID(agent["id"]), unread_only, limit
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.get("/v1/state/{namespace}/{key}")
async def get_state(namespace: str, key: str, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        value = await store.get_state(UUID(agent["workspace_id"]), namespace, key)
    except StoreError as exc:
        raise as_http_error(exc) from exc
    if not value:
        raise HTTPException(status_code=404, detail="state key not found")
    return value


@app.put("/v1/state/{namespace}/{key}")
async def write_state(namespace: str, key: str, body: StateWrite, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        return await store.write_state(
            UUID(agent["workspace_id"]), UUID(agent["id"]), namespace, key,
            body.value, body.expected_version
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc


@app.post("/v1/approvals", status_code=status.HTTP_201_CREATED)
async def request_approval(body: ApprovalCreate, agent: Agent, store: Store) -> dict[str, Any]:
    try:
        return await store.request_approval(
            UUID(agent["workspace_id"]), UUID(agent["id"]), serialize(body)
        )
    except StoreError as exc:
        raise as_http_error(exc) from exc

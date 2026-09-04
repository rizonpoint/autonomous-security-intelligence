from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field


class AgentIdentity(BaseModel):
    id: UUID
    workspace_id: UUID
    organization_id: UUID
    name: str
    role: str
    authority_level: int
    capabilities: list[str]
    status: str
    max_concurrency: int


class AdminAgentCreate(BaseModel):
    workspace_id: UUID
    name: str = Field(min_length=1, max_length=120)
    role: str = Field(min_length=1, max_length=240)
    authority_level: int = Field(default=1, ge=0, le=4)
    capabilities: list[str] = Field(default_factory=list, max_length=100)
    max_concurrency: int = Field(default=1, ge=1, le=20)
    credential_label: str = Field(default="primary", min_length=1, max_length=120)
    expires_at: datetime | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class AdminAgentCreated(BaseModel):
    agent: AgentIdentity
    credential_id: UUID
    api_key: str
    warning: str = "Store this key securely. It cannot be retrieved again."


class Organization(BaseModel):
    id: UUID
    slug: str
    name: str
    status: str
    metadata: dict[str, Any]


class AdminOrganizationCreate(BaseModel):
    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=120)
    name: str = Field(min_length=1, max_length=160)
    metadata: dict[str, Any] = Field(default_factory=dict)


class Workspace(BaseModel):
    id: UUID
    organization_id: UUID
    venture_id: UUID | None = None
    slug: str
    name: str
    kind: str
    purpose: str | None = None
    status: str
    metadata: dict[str, Any]


class AdminWorkspaceCreate(BaseModel):
    organization_id: UUID
    venture_id: UUID | None = None
    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=120)
    name: str = Field(min_length=1, max_length=160)
    kind: Literal["business", "department", "client", "internal"]
    purpose: str | None = Field(default=None, max_length=1000)
    metadata: dict[str, Any] = Field(default_factory=dict)


class Venture(BaseModel):
    id: UUID
    organization_id: UUID
    slug: str
    name: str
    venture_type: str
    stage: str
    thesis: str | None = None
    business_model: str | None = None
    status: str
    metadata: dict[str, Any]


class AdminVentureCreate(BaseModel):
    organization_id: UUID
    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=120)
    name: str = Field(min_length=1, max_length=160)
    venture_type: Literal["operating", "client", "proof_of_concept", "sandbox"] = "operating"
    stage: Literal[
        "idea", "validation", "launch", "operating", "scaling", "paused", "archived"
    ] = "validation"
    thesis: str | None = Field(default=None, max_length=2000)
    business_model: str | None = Field(default=None, max_length=1000)
    metadata: dict[str, Any] = Field(default_factory=dict)


class ModelProvider(BaseModel):
    id: UUID
    slug: str
    name: str
    api_family: str
    status: str
    metadata: dict[str, Any]


class AdminModelProviderCreate(BaseModel):
    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=120)
    name: str = Field(min_length=1, max_length=160)
    api_family: str = Field(min_length=1, max_length=120)
    metadata: dict[str, Any] = Field(default_factory=dict)


class ModelDeployment(BaseModel):
    id: UUID
    provider_id: UUID
    organization_id: UUID | None = None
    model_key: str
    display_name: str
    endpoint_class: str
    credential_ref: str | None = None
    capabilities: list[str]
    context_window_tokens: int | None = None
    max_output_tokens: int | None = None
    input_usd_per_million: float | None = None
    output_usd_per_million: float | None = None
    pricing_effective_at: datetime | None = None
    data_residency: str | None = None
    status: str
    metadata: dict[str, Any]


class AdminModelDeploymentCreate(BaseModel):
    provider_id: UUID
    organization_id: UUID | None = None
    model_key: str = Field(min_length=1, max_length=240)
    display_name: str = Field(min_length=1, max_length=240)
    endpoint_class: Literal["hosted", "dedicated", "self_hosted", "bot_runtime"] = "hosted"
    credential_ref: str | None = Field(default=None, max_length=500)
    capabilities: list[str] = Field(default_factory=list, max_length=100)
    context_window_tokens: int | None = Field(default=None, gt=0)
    max_output_tokens: int | None = Field(default=None, gt=0)
    input_usd_per_million: float | None = Field(default=None, ge=0)
    output_usd_per_million: float | None = Field(default=None, ge=0)
    pricing_effective_at: datetime | None = None
    data_residency: str | None = Field(default=None, max_length=120)
    metadata: dict[str, Any] = Field(default_factory=dict)


class TaskProfile(BaseModel):
    id: UUID
    organization_id: UUID
    venture_id: UUID | None = None
    slug: str
    name: str
    required_capabilities: list[str]
    risk_tier: str
    minimum_quality_score: float | None = None
    max_latency_ms: int | None = None
    max_cost_usd: float | None = None
    max_turns: int
    max_tool_calls: int
    allowed_provider_slugs: list[str]
    allowed_model_keys: list[str]
    data_classification: str
    status: str
    metadata: dict[str, Any]


class AdminTaskProfileCreate(BaseModel):
    organization_id: UUID
    venture_id: UUID | None = None
    slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=120)
    name: str = Field(min_length=1, max_length=160)
    required_capabilities: list[str] = Field(default_factory=list, max_length=100)
    risk_tier: Literal["low", "medium", "high", "critical"] = "low"
    minimum_quality_score: float | None = Field(default=None, ge=0, le=1)
    max_latency_ms: int | None = Field(default=None, gt=0)
    max_cost_usd: float | None = Field(default=None, ge=0)
    max_turns: int = Field(default=8, ge=1, le=100)
    max_tool_calls: int = Field(default=20, ge=0, le=200)
    allowed_provider_slugs: list[str] = Field(default_factory=list, max_length=100)
    allowed_model_keys: list[str] = Field(default_factory=list, max_length=100)
    data_classification: Literal["public", "internal", "confidential", "restricted"] = "internal"
    metadata: dict[str, Any] = Field(default_factory=dict)


class WorkItemCreate(BaseModel):
    work_type: str = Field(min_length=1, max_length=120)
    title: str = Field(min_length=1, max_length=300)
    priority: int = Field(default=50, ge=0, le=100)
    required_capabilities: list[str] = Field(default_factory=list)
    input: dict[str, Any] = Field(default_factory=dict)
    idempotency_key: str | None = Field(default=None, max_length=240)
    assigned_to: UUID | None = None
    parent_id: UUID | None = None
    due_at: datetime | None = None
    max_retries: int = Field(default=2, ge=0, le=10)
    queue: str = Field(default="default", min_length=1, max_length=120)
    workflow_name: str | None = Field(default=None, max_length=120)
    workflow_version: str | None = Field(default=None, max_length=80)
    policy_version: str | None = Field(default=None, max_length=80)
    prompt_version: str | None = Field(default=None, max_length=80)
    toolset_version: str | None = Field(default=None, max_length=80)


class ClaimRequest(BaseModel):
    lease_seconds: int = Field(default=900, ge=30, le=3600)


class HeartbeatRequest(BaseModel):
    lease_token: UUID
    lease_version: int = Field(ge=1)
    extend_seconds: int = Field(default=300, ge=30, le=900)


class CompleteRequest(BaseModel):
    lease_token: UUID
    lease_version: int = Field(ge=1)
    output: dict[str, Any] = Field(default_factory=dict)


class FailRequest(BaseModel):
    lease_token: UUID
    lease_version: int = Field(ge=1)
    failure_class: Literal[
        "transient", "rate_limited", "invalid_input", "policy",
        "permission", "dependency", "bug", "unknown"
    ] = "unknown"
    error: dict[str, Any]
    retryable: bool = True


class MessageCreate(BaseModel):
    to_agent: UUID | None = None
    work_item_id: UUID | None = None
    kind: Literal["task", "result", "question", "review", "system"]
    body: dict[str, Any]


class StateWrite(BaseModel):
    value: dict[str, Any]
    expected_version: int = Field(ge=0)


class ApprovalCreate(BaseModel):
    work_item_id: UUID
    action_type: str = Field(min_length=1, max_length=120)
    summary: str = Field(min_length=1, max_length=1000)
    payload: dict[str, Any]
    risk: Literal["low", "medium", "high", "critical"]
    expires_at: datetime | None = None

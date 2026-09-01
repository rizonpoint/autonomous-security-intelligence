from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field


class AgentIdentity(BaseModel):
    id: UUID
    name: str
    role: str
    authority_level: int
    capabilities: list[str]
    status: str
    max_concurrency: int


class AdminAgentCreate(BaseModel):
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


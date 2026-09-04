import {
  constantTimeTextEqual,
  issueAgentKey,
  parseAgentKey,
  verifyAgentSecret,
} from "./security.ts";

declare const Deno:
  | {
      env: { get(name: string): string | undefined };
      serve(handler: (request: Request) => Response | Promise<Response>): void;
    }
  | undefined;

const FUNCTION_NAME = "control-plane";
const MAX_BODY_BYTES = 1024 * 1024;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FAILURE_CLASSES = new Set([
  "transient",
  "rate_limited",
  "invalid_input",
  "policy",
  "permission",
  "dependency",
  "bug",
  "unknown",
]);
const MESSAGE_KINDS = new Set(["task", "result", "question", "review"]);
const RISKS = new Set(["low", "medium", "high", "critical"]);
const WORKSPACE_KINDS = new Set(["business", "department", "client", "internal"]);
const VENTURE_TYPES = new Set(["operating", "client", "proof_of_concept", "sandbox"]);
const VENTURE_STAGES = new Set([
  "idea", "validation", "launch", "operating", "scaling", "paused", "archived",
]);
const ENDPOINT_CLASSES = new Set(["hosted", "dedicated", "self_hosted", "bot_runtime"]);
const DATA_CLASSIFICATIONS = new Set(["public", "internal", "confidential", "restricted"]);
const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

type JsonObject = Record<string, unknown>;

interface AgentIdentity extends JsonObject {
  id: string;
  workspace_id: string;
  organization_id: string;
  name: string;
  role: string;
  authority_level: number;
  capabilities: string[];
  status: string;
  max_concurrency: number;
}

export function canDelegateWork(
  agent: Pick<AgentIdentity, "authority_level" | "capabilities">,
): boolean {
  return agent.authority_level >= 2 || agent.capabilities.includes("delegate");
}

function requiredSlug(body: JsonObject, key = "slug"): string {
  const value = requiredString(body, key, 120);
  if (!SLUG_PATTERN.test(value)) {
    throw new HttpError(422, `${key} must be a lowercase hyphenated slug`);
  }
  return value;
}

class HttpError extends Error {
  readonly status: number;
  readonly detail: string;

  constructor(status: number, detail: string) {
    super(detail);
    this.status = status;
    this.detail = detail;
  }
}

function env(name: string): string {
  const value = typeof Deno === "undefined" ? undefined : Deno.env.get(name);
  if (!value) {
    throw new HttpError(503, `server configuration ${name} is unavailable`);
  }
  return value;
}

function jsonResponse(status: number, body: unknown, requestId: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Request-ID": requestId,
    },
  });
}

function requestId(request: Request): string {
  const supplied = request.headers.get("x-request-id");
  if (supplied && /^[A-Za-z0-9._:-]{1,128}$/.test(supplied)) {
    return supplied;
  }
  return crypto.randomUUID();
}

export function normalizePath(pathname: string): string {
  const marker = `/${FUNCTION_NAME}`;
  const markerIndex = pathname.lastIndexOf(marker);
  const path = markerIndex >= 0
    ? pathname.slice(markerIndex + marker.length)
    : pathname;
  if (!path || path === "/") {
    return "/";
  }
  return path.endsWith("/") ? path.slice(0, -1) : path;
}

function asObject(value: unknown, name = "request body"): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(422, `${name} must be a JSON object`);
  }
  return value as JsonObject;
}

async function parseJsonBody(request: Request): Promise<JsonObject> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    throw new HttpError(413, "request body exceeds 1 MiB");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    throw new HttpError(413, "request body exceeds 1 MiB");
  }
  if (!text) {
    return {};
  }
  try {
    return asObject(JSON.parse(text));
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "request body is not valid JSON");
  }
}

function requiredString(
  body: JsonObject,
  key: string,
  maxLength: number,
): string {
  const value = body[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpError(422, `${key} is required`);
  }
  if (value.length > maxLength) {
    throw new HttpError(422, `${key} exceeds ${maxLength} characters`);
  }
  return value;
}

function boundedInteger(
  value: unknown,
  key: string,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  const resolved = value ?? fallback;
  if (
    !Number.isInteger(resolved) ||
    (resolved as number) < minimum ||
    (resolved as number) > maximum
  ) {
    throw new HttpError(422, `${key} must be between ${minimum} and ${maximum}`);
  }
  return resolved as number;
}

function optionalNumber(
  value: unknown,
  key: string,
  minimum = 0,
  maximum = Number.MAX_SAFE_INTEGER,
): number | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new HttpError(422, `${key} must be a number between ${minimum} and ${maximum}`);
  }
  return value;
}

function optionalString(value: unknown, key: string, maxLength: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length > maxLength) {
    throw new HttpError(422, `${key} must be a string of at most ${maxLength} characters`);
  }
  return value;
}

function optionalUuid(value: unknown, key: string): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new HttpError(422, `${key} must be a UUID`);
  }
  return value;
}

function requiredUuid(value: unknown, key: string): string {
  const resolved = optionalUuid(value, key);
  if (!resolved) throw new HttpError(422, `${key} is required`);
  return resolved;
}

function stringArray(value: unknown, key: string, maximum = 100): string[] {
  if (value === undefined) return [];
  if (
    !Array.isArray(value) ||
    value.length > maximum ||
    value.some((entry) => typeof entry !== "string" || entry.length === 0)
  ) {
    throw new HttpError(422, `${key} must be an array of non-empty strings`);
  }
  return value as string[];
}

function optionalTimestamp(value: unknown, key: string): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || Number.isNaN(Date.parse(value))) {
    throw new HttpError(422, `${key} must be an ISO-8601 timestamp`);
  }
  return value;
}

function objectValue(value: unknown, key: string): JsonObject {
  if (value === undefined) return {};
  return asObject(value, key);
}

function one(value: unknown): JsonObject | null {
  if (Array.isArray(value)) {
    return value.length ? asObject(value[0], "database response") : null;
  }
  return value === null || value === undefined
    ? null
    : asObject(value, "database response");
}

function query(params: Record<string, string>): string {
  return new URLSearchParams(params).toString();
}

async function databaseRequest(
  method: string,
  path: string,
  body?: unknown,
  prefer?: string,
): Promise<unknown> {
  const serviceRoleKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const headers: Record<string, string> = {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    Accept: "application/json",
  };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (prefer) headers.Prefer = prefer;

  let response: Response;
  try {
    response = await fetch(`${env("SUPABASE_URL").replace(/\/$/, "")}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new HttpError(502, "control-plane database is unavailable");
  }

  const text = await response.text();
  let payload: unknown = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }
  if (!response.ok) {
    const record = payload && typeof payload === "object"
      ? payload as Record<string, unknown>
      : {};
    const code = typeof record.code === "string" ? record.code : "";
    const message = [record.message, record.error_description, record.hint]
      .find((value) => typeof value === "string") as string | undefined;
    const status = code === "23505" || code === "P0001"
      ? 409
      : response.status;
    throw new HttpError(status, message ?? "database request failed");
  }
  return payload;
}

async function rpc(name: string, body: JsonObject): Promise<unknown> {
  return await databaseRequest("POST", `/rest/v1/rpc/${name}`, body);
}

async function authenticateAgent(request: Request): Promise<AgentIdentity> {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization);
  const parsed = match ? parseAgentKey(match[1]) : null;
  if (!parsed) {
    throw new HttpError(401, "agent bearer credential required");
  }

  const credentials = await databaseRequest(
    "GET",
    `/rest/v1/agent_credentials?${query({
      id: `eq.${parsed.credentialId}`,
      select: "id,workspace_id,agent_id,key_hash,expires_at,revoked_at",
      limit: "1",
    })}`,
  );
  const credential = one(credentials);
  if (
    !credential ||
    credential.revoked_at !== null ||
    typeof credential.key_hash !== "string" ||
    !verifyAgentSecret(parsed.secret, credential.key_hash)
  ) {
    throw new HttpError(401, "invalid agent credential");
  }
  if (
    typeof credential.expires_at === "string" &&
    Date.parse(credential.expires_at) <= Date.now()
  ) {
    throw new HttpError(401, "agent credential has expired");
  }

  const agents = await databaseRequest(
    "GET",
    `/rest/v1/agents?${query({
      id: `eq.${String(credential.agent_id)}`,
      workspace_id: `eq.${String(credential.workspace_id)}`,
      select:
        "id,workspace_id,name,role,authority_level,capabilities,status,max_concurrency",
      limit: "1",
    })}`,
  );
  const agent = one(agents) as AgentIdentity | null;
  if (!agent || agent.status === "disabled") {
    throw new HttpError(403, "agent is disabled");
  }

  const workspace = one(await databaseRequest(
    "GET",
    `/rest/v1/workspaces?${query({
      id: `eq.${agent.workspace_id}`,
      select: "id,organization_id,status",
      limit: "1",
    })}`,
  ));
  if (!workspace || workspace.status !== "active") {
    throw new HttpError(403, "agent workspace is unavailable");
  }
  const organization = one(await databaseRequest(
    "GET",
    `/rest/v1/organizations?${query({
      id: `eq.${String(workspace.organization_id)}`,
      select: "id,status",
      limit: "1",
    })}`,
  ));
  if (!organization || organization.status !== "active") {
    throw new HttpError(403, "agent organization is unavailable");
  }
  agent.organization_id = String(organization.id);

  const now = new Date().toISOString();
  await Promise.all([
    databaseRequest(
      "PATCH",
      `/rest/v1/agent_credentials?${query({ id: `eq.${parsed.credentialId}` })}`,
      { last_used_at: now },
    ),
    databaseRequest(
      "PATCH",
      `/rest/v1/agents?${query({ id: `eq.${agent.id}` })}`,
      { last_seen_at: now },
    ),
  ]);
  return agent;
}

function requireAdmin(request: Request): void {
  const expected = env("CONTROL_PLANE_ADMIN_TOKEN");
  const supplied = request.headers.get("x-admin-token") ?? "";
  if (!supplied || !constantTimeTextEqual(supplied, expected)) {
    throw new HttpError(401, "valid admin token required");
  }
}

async function createAgent(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  const name = requiredString(body, "name", 120);
  const role = requiredString(body, "role", 240);
  const issued = issueAgentKey();
  const result = one(await rpc("register_agent", {
    p_workspace_id: requiredUuid(body.workspace_id, "workspace_id"),
    p_credential_id: issued.credentialId,
    p_key_hash: issued.encodedHash,
    p_name: name,
    p_role: role,
    p_authority_level: boundedInteger(
      body.authority_level,
      "authority_level",
      0,
      4,
      1,
    ),
    p_capabilities: stringArray(body.capabilities, "capabilities"),
    p_max_concurrency: boundedInteger(
      body.max_concurrency,
      "max_concurrency",
      1,
      20,
      1,
    ),
    p_credential_label: typeof body.credential_label === "string"
      ? body.credential_label
      : "primary",
    p_expires_at: optionalTimestamp(body.expires_at, "expires_at"),
    p_metadata: objectValue(body.metadata, "metadata"),
  }));
  if (!result) throw new HttpError(500, "agent registration returned no data");
  return {
    agent: result.agent,
    credential_id: issued.credentialId,
    api_key: issued.plaintext,
    warning: "Store this key securely. It cannot be retrieved again.",
  };
}

async function createOrganization(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  return one(await databaseRequest(
    "POST",
    "/rest/v1/organizations",
    {
      slug: requiredSlug(body),
      name: requiredString(body, "name", 160),
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listOrganizations(request: Request): Promise<unknown> {
  requireAdmin(request);
  return await databaseRequest(
    "GET",
    `/rest/v1/organizations?${query({ select: "*", order: "created_at.asc" })}`,
  );
}

async function createWorkspace(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  const kind = requiredString(body, "kind", 40);
  if (!WORKSPACE_KINDS.has(kind)) {
    throw new HttpError(422, "kind must be business, department, client, or internal");
  }
  const purpose = body.purpose;
  if (purpose !== undefined && purpose !== null &&
    (typeof purpose !== "string" || purpose.length > 1000)) {
    throw new HttpError(422, "purpose must be a string of at most 1000 characters");
  }
  return one(await databaseRequest(
    "POST",
    "/rest/v1/workspaces",
    {
      organization_id: requiredUuid(body.organization_id, "organization_id"),
      venture_id: optionalUuid(body.venture_id, "venture_id"),
      slug: requiredSlug(body),
      name: requiredString(body, "name", 160),
      kind,
      purpose: purpose ?? null,
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listWorkspaces(request: Request, url: URL): Promise<unknown> {
  requireAdmin(request);
  const params: Record<string, string> = {
    select: "*",
    order: "created_at.asc",
  };
  const organizationId = url.searchParams.get("organization_id");
  if (organizationId) {
    params.organization_id = `eq.${requiredUuid(organizationId, "organization_id")}`;
  }
  const ventureId = url.searchParams.get("venture_id");
  if (ventureId) {
    params.venture_id = `eq.${requiredUuid(ventureId, "venture_id")}`;
  }
  return await databaseRequest(
    "GET",
    `/rest/v1/workspaces?${query(params)}`,
  );
}

async function createVenture(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  const ventureType = typeof body.venture_type === "string" ? body.venture_type : "operating";
  const stage = typeof body.stage === "string" ? body.stage : "validation";
  if (!VENTURE_TYPES.has(ventureType)) throw new HttpError(422, "venture_type is invalid");
  if (!VENTURE_STAGES.has(stage)) throw new HttpError(422, "stage is invalid");
  return one(await databaseRequest(
    "POST",
    "/rest/v1/ventures",
    {
      organization_id: requiredUuid(body.organization_id, "organization_id"),
      slug: requiredSlug(body),
      name: requiredString(body, "name", 160),
      venture_type: ventureType,
      stage,
      thesis: optionalString(body.thesis, "thesis", 2000),
      business_model: optionalString(body.business_model, "business_model", 1000),
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listVentures(request: Request, url: URL): Promise<unknown> {
  requireAdmin(request);
  const params: Record<string, string> = { select: "*", order: "created_at.asc" };
  const organizationId = url.searchParams.get("organization_id");
  if (organizationId) {
    params.organization_id = `eq.${requiredUuid(organizationId, "organization_id")}`;
  }
  return await databaseRequest("GET", `/rest/v1/ventures?${query(params)}`);
}

async function listVentureBlueprints(request: Request): Promise<unknown> {
  requireAdmin(request);
  return await databaseRequest(
    "GET",
    `/rest/v1/venture_blueprints?${query({
      select: "*,venture_blueprint_versions(*)",
      order: "created_at.asc",
    })}`,
  );
}

async function createModelProvider(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  return one(await databaseRequest(
    "POST",
    "/rest/v1/model_providers",
    {
      slug: requiredSlug(body),
      name: requiredString(body, "name", 160),
      api_family: requiredString(body, "api_family", 120),
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listModelProviders(request: Request): Promise<unknown> {
  requireAdmin(request);
  return await databaseRequest(
    "GET",
    `/rest/v1/model_providers?${query({ select: "*", order: "created_at.asc" })}`,
  );
}

async function createModelDeployment(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  const endpointClass = typeof body.endpoint_class === "string" ? body.endpoint_class : "hosted";
  if (!ENDPOINT_CLASSES.has(endpointClass)) throw new HttpError(422, "endpoint_class is invalid");
  return one(await databaseRequest(
    "POST",
    "/rest/v1/model_deployments",
    {
      provider_id: requiredUuid(body.provider_id, "provider_id"),
      organization_id: optionalUuid(body.organization_id, "organization_id"),
      model_key: requiredString(body, "model_key", 240),
      display_name: requiredString(body, "display_name", 240),
      endpoint_class: endpointClass,
      credential_ref: optionalString(body.credential_ref, "credential_ref", 500),
      capabilities: stringArray(body.capabilities, "capabilities"),
      context_window_tokens: optionalNumber(body.context_window_tokens, "context_window_tokens", 1),
      max_output_tokens: optionalNumber(body.max_output_tokens, "max_output_tokens", 1),
      input_usd_per_million: optionalNumber(body.input_usd_per_million, "input_usd_per_million"),
      output_usd_per_million: optionalNumber(body.output_usd_per_million, "output_usd_per_million"),
      pricing_effective_at: optionalTimestamp(body.pricing_effective_at, "pricing_effective_at"),
      data_residency: optionalString(body.data_residency, "data_residency", 120),
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listModelDeployments(request: Request, url: URL): Promise<unknown> {
  requireAdmin(request);
  const params: Record<string, string> = { select: "*", order: "created_at.asc" };
  const organizationId = url.searchParams.get("organization_id");
  if (organizationId) {
    const id = requiredUuid(organizationId, "organization_id");
    params.or = `(organization_id.is.null,organization_id.eq.${id})`;
  }
  return await databaseRequest("GET", `/rest/v1/model_deployments?${query(params)}`);
}

async function createTaskProfile(request: Request): Promise<unknown> {
  requireAdmin(request);
  const body = await parseJsonBody(request);
  const riskTier = typeof body.risk_tier === "string" ? body.risk_tier : "low";
  const classification = typeof body.data_classification === "string"
    ? body.data_classification
    : "internal";
  if (!RISKS.has(riskTier)) throw new HttpError(422, "risk_tier is invalid");
  if (!DATA_CLASSIFICATIONS.has(classification)) {
    throw new HttpError(422, "data_classification is invalid");
  }
  return one(await databaseRequest(
    "POST",
    "/rest/v1/task_profiles",
    {
      organization_id: requiredUuid(body.organization_id, "organization_id"),
      venture_id: optionalUuid(body.venture_id, "venture_id"),
      slug: requiredSlug(body),
      name: requiredString(body, "name", 160),
      required_capabilities: stringArray(body.required_capabilities, "required_capabilities"),
      risk_tier: riskTier,
      minimum_quality_score: optionalNumber(body.minimum_quality_score, "minimum_quality_score", 0, 1),
      max_latency_ms: optionalNumber(body.max_latency_ms, "max_latency_ms", 1),
      max_cost_usd: optionalNumber(body.max_cost_usd, "max_cost_usd"),
      max_turns: boundedInteger(body.max_turns, "max_turns", 1, 100, 8),
      max_tool_calls: boundedInteger(body.max_tool_calls, "max_tool_calls", 0, 200, 20),
      allowed_provider_slugs: stringArray(body.allowed_provider_slugs, "allowed_provider_slugs"),
      allowed_model_keys: stringArray(body.allowed_model_keys, "allowed_model_keys"),
      data_classification: classification,
      metadata: objectValue(body.metadata, "metadata"),
    },
    "return=representation",
  ));
}

async function listTaskProfiles(request: Request, url: URL): Promise<unknown> {
  requireAdmin(request);
  const organizationId = requiredUuid(
    url.searchParams.get("organization_id"),
    "organization_id",
  );
  return await databaseRequest(
    "GET",
    `/rest/v1/task_profiles?${query({
      organization_id: `eq.${organizationId}`,
      select: "*",
      order: "created_at.asc",
    })}`,
  );
}

async function createWorkItem(
  request: Request,
  agent: AgentIdentity,
): Promise<unknown> {
  if (!canDelegateWork(agent)) {
    throw new HttpError(403, "agent lacks delegation authority");
  }
  const body = await parseJsonBody(request);
  const result = await databaseRequest(
    "POST",
    "/rest/v1/work_items",
    {
      workspace_id: agent.workspace_id,
      requested_by: agent.id,
      work_type: requiredString(body, "work_type", 120),
      title: requiredString(body, "title", 300),
      priority: boundedInteger(body.priority, "priority", 0, 100, 50),
      required_capabilities: stringArray(
        body.required_capabilities,
        "required_capabilities",
      ),
      input: objectValue(body.input, "input"),
      idempotency_key: body.idempotency_key ?? null,
      assigned_to: optionalUuid(body.assigned_to, "assigned_to"),
      parent_id: optionalUuid(body.parent_id, "parent_id"),
      due_at: optionalTimestamp(body.due_at, "due_at"),
      max_retries: boundedInteger(body.max_retries, "max_retries", 0, 10, 2),
      queue: typeof body.queue === "string" ? body.queue : "default",
      workflow_name: body.workflow_name ?? null,
      workflow_version: body.workflow_version ?? null,
      policy_version: body.policy_version ?? null,
      prompt_version: body.prompt_version ?? null,
      toolset_version: body.toolset_version ?? null,
    },
    "return=representation",
  );
  return one(result);
}

async function getWorkItem(
  workItemId: string,
  agent: AgentIdentity,
): Promise<unknown> {
  const result = one(await databaseRequest(
    "GET",
    `/rest/v1/work_items?${query({
      id: `eq.${workItemId}`,
      workspace_id: `eq.${agent.workspace_id}`,
      select: "*",
      limit: "1",
    })}`,
  ));
  if (!result) throw new HttpError(404, "work item not found");
  if (result.requested_by !== agent.id && result.assigned_to !== agent.id) {
    throw new HttpError(403, "agent is not a participant in this work item");
  }
  return result;
}

async function claimWork(request: Request, agent: AgentIdentity): Promise<unknown> {
  const body = await parseJsonBody(request);
  return one(await rpc("claim_next_work_item", {
    p_agent_id: agent.id,
    p_lease_seconds: boundedInteger(
      body.lease_seconds,
      "lease_seconds",
      30,
      3600,
      900,
    ),
  }));
}

async function heartbeat(
  request: Request,
  agent: AgentIdentity,
  workItemId: string,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  const expiresAt = await rpc("heartbeat_work_attempt", {
    p_work_item_id: workItemId,
    p_agent_id: agent.id,
    p_lease_token: requiredUuid(body.lease_token, "lease_token"),
    p_lease_version: boundedInteger(
      body.lease_version,
      "lease_version",
      1,
      Number.MAX_SAFE_INTEGER,
      0,
    ),
    p_extend_seconds: boundedInteger(
      body.extend_seconds,
      "extend_seconds",
      30,
      900,
      300,
    ),
  });
  return { lease_expires_at: expiresAt };
}

async function completeWork(
  request: Request,
  agent: AgentIdentity,
  workItemId: string,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  return one(await rpc("complete_work_attempt", {
    p_work_item_id: workItemId,
    p_agent_id: agent.id,
    p_lease_token: requiredUuid(body.lease_token, "lease_token"),
    p_lease_version: boundedInteger(
      body.lease_version,
      "lease_version",
      1,
      Number.MAX_SAFE_INTEGER,
      0,
    ),
    p_output: objectValue(body.output, "output"),
  }));
}

async function failWork(
  request: Request,
  agent: AgentIdentity,
  workItemId: string,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  const failureClass = body.failure_class ?? "unknown";
  if (typeof failureClass !== "string" || !FAILURE_CLASSES.has(failureClass)) {
    throw new HttpError(422, "failure_class is invalid");
  }
  return one(await rpc("fail_work_attempt", {
    p_work_item_id: workItemId,
    p_agent_id: agent.id,
    p_lease_token: requiredUuid(body.lease_token, "lease_token"),
    p_lease_version: boundedInteger(
      body.lease_version,
      "lease_version",
      1,
      Number.MAX_SAFE_INTEGER,
      0,
    ),
    p_failure_class: failureClass,
    p_error: objectValue(body.error, "error"),
    p_retryable: body.retryable === undefined ? true : body.retryable === true,
  }));
}

async function sendMessage(
  request: Request,
  agent: AgentIdentity,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  const kind = body.kind;
  if (typeof kind !== "string" || !MESSAGE_KINDS.has(kind)) {
    throw new HttpError(422, "kind must be task, result, question, or review");
  }
  const result = await databaseRequest(
    "POST",
    "/rest/v1/messages",
    {
      workspace_id: agent.workspace_id,
      from_agent: agent.id,
      to_agent: requiredUuid(body.to_agent, "to_agent"),
      work_item_id: optionalUuid(body.work_item_id, "work_item_id"),
      kind,
      body: objectValue(body.body, "body"),
    },
    "return=representation",
  );
  return one(result);
}

async function inbox(url: URL, agent: AgentIdentity): Promise<unknown> {
  const unreadOnly = url.searchParams.get("unread_only") !== "false";
  const rawLimit = Number(url.searchParams.get("limit") ?? "100");
  const limit = boundedInteger(rawLimit, "limit", 1, 500, 100);
  const params: Record<string, string> = {
    workspace_id: `eq.${agent.workspace_id}`,
    to_agent: `eq.${agent.id}`,
    select: "*",
    order: "created_at.asc",
    limit: String(limit),
  };
  if (unreadOnly) params.read_at = "is.null";
  return await databaseRequest(
    "GET",
    `/rest/v1/messages?${query(params)}`,
  );
}

async function getState(
  namespace: string,
  key: string,
  agent: AgentIdentity,
): Promise<unknown> {
  const result = one(await databaseRequest(
    "GET",
    `/rest/v1/shared_state?${query({
      workspace_id: `eq.${agent.workspace_id}`,
      namespace: `eq.${namespace}`,
      key: `eq.${key}`,
      select: "*",
      limit: "1",
    })}`,
  ));
  if (!result) throw new HttpError(404, "state key not found");
  return result;
}

async function writeState(
  request: Request,
  namespace: string,
  key: string,
  agent: AgentIdentity,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  return one(await rpc("compare_and_swap_shared_state", {
    p_workspace_id: agent.workspace_id,
    p_namespace: namespace,
    p_key: key,
    p_value: objectValue(body.value, "value"),
    p_expected_version: boundedInteger(
      body.expected_version,
      "expected_version",
      0,
      Number.MAX_SAFE_INTEGER,
      -1,
    ),
    p_updated_by: agent.id,
  }));
}

async function requestApproval(
  request: Request,
  agent: AgentIdentity,
): Promise<unknown> {
  const body = await parseJsonBody(request);
  const risk = body.risk;
  if (typeof risk !== "string" || !RISKS.has(risk)) {
    throw new HttpError(422, "risk must be low, medium, high, or critical");
  }
  const result = await databaseRequest(
    "POST",
    "/rest/v1/approvals",
    {
      workspace_id: agent.workspace_id,
      requested_by: agent.id,
      work_item_id: requiredUuid(body.work_item_id, "work_item_id"),
      action_type: requiredString(body, "action_type", 120),
      summary: requiredString(body, "summary", 1000),
      payload: objectValue(body.payload, "payload"),
      risk,
      expires_at: optionalTimestamp(body.expires_at, "expires_at"),
    },
    "return=representation",
  );
  return one(result);
}

export async function handleRequest(request: Request): Promise<Response> {
  const id = requestId(request);
  const startedAt = performance.now();
  try {
    const url = new URL(request.url);
    const path = normalizePath(url.pathname);

    if (request.method === "GET" && path === "/health") {
      return jsonResponse(200, { status: "ok", version: "0.4.0" }, id);
    }
    if (request.method === "POST" && path === "/v1/admin/organizations") {
      return jsonResponse(201, await createOrganization(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/organizations") {
      return jsonResponse(200, await listOrganizations(request), id);
    }
    if (request.method === "POST" && path === "/v1/admin/workspaces") {
      return jsonResponse(201, await createWorkspace(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/workspaces") {
      return jsonResponse(200, await listWorkspaces(request, url), id);
    }
    if (request.method === "POST" && path === "/v1/admin/agents") {
      return jsonResponse(201, await createAgent(request), id);
    }
    if (request.method === "POST" && path === "/v1/admin/ventures") {
      return jsonResponse(201, await createVenture(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/ventures") {
      return jsonResponse(200, await listVentures(request, url), id);
    }
    if (request.method === "GET" && path === "/v1/admin/venture-blueprints") {
      return jsonResponse(200, await listVentureBlueprints(request), id);
    }
    if (request.method === "POST" && path === "/v1/admin/model-providers") {
      return jsonResponse(201, await createModelProvider(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/model-providers") {
      return jsonResponse(200, await listModelProviders(request), id);
    }
    if (request.method === "POST" && path === "/v1/admin/model-deployments") {
      return jsonResponse(201, await createModelDeployment(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/model-deployments") {
      return jsonResponse(200, await listModelDeployments(request, url), id);
    }
    if (request.method === "POST" && path === "/v1/admin/task-profiles") {
      return jsonResponse(201, await createTaskProfile(request), id);
    }
    if (request.method === "GET" && path === "/v1/admin/task-profiles") {
      return jsonResponse(200, await listTaskProfiles(request, url), id);
    }

    const agent = await authenticateAgent(request);
    if (request.method === "GET" && path === "/v1/me") {
      return jsonResponse(200, agent, id);
    }
    if (request.method === "POST" && path === "/v1/work-items") {
      return jsonResponse(201, await createWorkItem(request, agent), id);
    }
    if (request.method === "POST" && path === "/v1/work-items/claim") {
      return jsonResponse(200, await claimWork(request, agent), id);
    }
    if (request.method === "POST" && path === "/v1/messages") {
      return jsonResponse(201, await sendMessage(request, agent), id);
    }
    if (request.method === "GET" && path === "/v1/messages/inbox") {
      return jsonResponse(200, await inbox(url, agent), id);
    }
    if (request.method === "POST" && path === "/v1/approvals") {
      return jsonResponse(201, await requestApproval(request, agent), id);
    }

    const workMatch = /^\/v1\/work-items\/([0-9a-f-]+)$/i.exec(path);
    if (request.method === "GET" && workMatch) {
      return jsonResponse(
        200,
        await getWorkItem(requiredUuid(workMatch[1], "work_item_id"), agent),
        id,
      );
    }
    const actionMatch =
      /^\/v1\/work-items\/([0-9a-f-]+)\/(heartbeat|complete|fail)$/i.exec(path);
    if (request.method === "POST" && actionMatch) {
      const workItemId = requiredUuid(actionMatch[1], "work_item_id");
      const action = actionMatch[2];
      const result = action === "heartbeat"
        ? await heartbeat(request, agent, workItemId)
        : action === "complete"
        ? await completeWork(request, agent, workItemId)
        : await failWork(request, agent, workItemId);
      return jsonResponse(200, result, id);
    }
    const stateMatch = /^\/v1\/state\/([^/]+)\/([^/]+)$/.exec(path);
    if (stateMatch) {
      const namespace = decodeURIComponent(stateMatch[1]);
      const key = decodeURIComponent(stateMatch[2]);
      if (request.method === "GET") {
        return jsonResponse(200, await getState(namespace, key, agent), id);
      }
      if (request.method === "PUT") {
        return jsonResponse(200, await writeState(request, namespace, key, agent), id);
      }
    }
    throw new HttpError(404, "route not found");
  } catch (error) {
    if (error instanceof HttpError) {
      return jsonResponse(error.status, { detail: error.detail }, id);
    }
    console.error(JSON.stringify({
      event: "unhandled_request_error",
      request_id: id,
      latency_ms: Math.round(performance.now() - startedAt),
    }));
    return jsonResponse(500, { detail: "internal server error" }, id);
  }
}

if (typeof Deno !== "undefined") {
  Deno.serve(handleRequest);
}

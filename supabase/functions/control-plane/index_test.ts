import assert from "node:assert/strict";
import test from "node:test";

import { canDelegateWork, handleRequest, normalizePath } from "./index.ts";

test("normalizes hosted and local Edge Function paths", () => {
  assert.equal(
    normalizePath("/functions/v1/control-plane/v1/messages/inbox"),
    "/v1/messages/inbox",
  );
  assert.equal(normalizePath("/control-plane/health/"), "/health");
  assert.equal(normalizePath("/health"), "/health");
});

test("delegation requires manager authority or an explicit capability", () => {
  assert.equal(canDelegateWork({ authority_level: 1, capabilities: [] }), false);
  assert.equal(
    canDelegateWork({ authority_level: 1, capabilities: ["delegate"] }),
    true,
  );
  assert.equal(canDelegateWork({ authority_level: 2, capabilities: [] }), true);
});

test("health is public, cache-disabled, and correlated", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/control-plane/health", {
      headers: { "x-request-id": "test-request-1" },
    }),
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-request-id"), "test-request-1");
  assert.deepEqual(await response.json(), { status: "ok", version: "0.4.0" });
});

test("protected routes fail closed without an agent credential", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/control-plane/v1/me"),
  );
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), {
    detail: "agent bearer credential required",
  });
});

test("admin route fails closed when its project secret is unavailable", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/control-plane/v1/admin/agents", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "test", role: "test" }),
    }),
  );
  assert.equal(response.status, 503);
});

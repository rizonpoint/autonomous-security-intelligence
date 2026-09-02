import assert from "node:assert/strict";
import test from "node:test";

import {
  constantTimeTextEqual,
  hashAgentSecret,
  issueAgentKey,
  parseAgentKey,
  verifyAgentSecret,
} from "./security.ts";

test("issued agent keys round-trip through the scrypt verifier", () => {
  const issued = issueAgentKey();
  const parsed = parseAgentKey(issued.plaintext);
  assert.ok(parsed);
  assert.equal(parsed.credentialId, issued.credentialId);
  assert.equal(verifyAgentSecret(parsed.secret, issued.encodedHash), true);
  assert.equal(verifyAgentSecret(`${parsed.secret}x`, issued.encodedHash), false);
});

test("TypeScript hashes match the Python control-plane encoding", () => {
  const secret = "interoperability-test-secret-0123456789";
  const salt = Uint8Array.from(Array.from({ length: 16 }, (_, index) => index));
  const encoded = hashAgentSecret(secret, salt);
  assert.equal(
    encoded,
    "scrypt$16384$8$1$AAECAwQFBgcICQoLDA0ODw$k6KqHq_mAxkrE_uIH1pSuCvb221YFm2D0JI26anFvAs",
  );
  assert.equal(verifyAgentSecret(secret, encoded), true);
});

test("malformed credentials and parameter substitution fail closed", () => {
  assert.equal(parseAgentKey("not-a-key"), null);
  assert.equal(
    parseAgentKey("asi.00000000-0000-0000-0000-000000000000.short"),
    null,
  );
  assert.equal(
    verifyAgentSecret(
      "secret",
      "scrypt$32768$8$1$AAECAwQFBgcICQoLDA0ODw$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ),
    false,
  );
});

test("admin-token comparison is exact", () => {
  assert.equal(constantTimeTextEqual("a".repeat(32), "a".repeat(32)), true);
  assert.equal(constantTimeTextEqual("a".repeat(32), "b".repeat(32)), false);
  assert.equal(constantTimeTextEqual("short", "longer"), false);
});

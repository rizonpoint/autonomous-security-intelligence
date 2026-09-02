import {
  randomBytes,
  randomUUID,
  scryptSync,
  timingSafeEqual,
} from "node:crypto";
import { Buffer } from "node:buffer";

export const SCRYPT_N = 2 ** 14;
export const SCRYPT_R = 8;
export const SCRYPT_P = 1;
export const SCRYPT_DKLEN = 32;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface IssuedAgentKey {
  credentialId: string;
  plaintext: string;
  encodedHash: string;
}

export interface ParsedAgentKey {
  credentialId: string;
  secret: string;
}

function encodeBase64Url(value: Uint8Array): string {
  return Buffer.from(value).toString("base64url");
}

function decodeBase64Url(value: string): Buffer {
  return Buffer.from(value, "base64url");
}

export function parseAgentKey(value: string): ParsedAgentKey | null {
  const [prefix, credentialId, secret, ...extra] = value.split(".");
  if (
    prefix !== "asi" ||
    !UUID_PATTERN.test(credentialId ?? "") ||
    (secret?.length ?? 0) < 32 ||
    extra.length > 0
  ) {
    return null;
  }
  return { credentialId, secret };
}

export function hashAgentSecret(
  secret: string,
  salt: Uint8Array = randomBytes(16),
): string {
  const derived = scryptSync(secret, salt, SCRYPT_DKLEN, {
    N: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
    maxmem: 64 * 1024 * 1024,
  });
  return [
    "scrypt",
    SCRYPT_N,
    SCRYPT_R,
    SCRYPT_P,
    encodeBase64Url(salt),
    encodeBase64Url(derived),
  ].join("$");
}

export function verifyAgentSecret(secret: string, encodedHash: string): boolean {
  try {
    const [algorithm, rawN, rawR, rawP, rawSalt, rawExpected, ...extra] =
      encodedHash.split("$");
    const n = Number(rawN);
    const r = Number(rawR);
    const p = Number(rawP);
    if (
      algorithm !== "scrypt" ||
      n !== SCRYPT_N ||
      r !== SCRYPT_R ||
      p !== SCRYPT_P ||
      !rawSalt ||
      !rawExpected ||
      extra.length > 0
    ) {
      return false;
    }

    const salt = decodeBase64Url(rawSalt);
    const expected = decodeBase64Url(rawExpected);
    if (salt.length !== 16 || expected.length !== SCRYPT_DKLEN) {
      return false;
    }
    const candidate = scryptSync(secret, salt, expected.length, {
      N: n,
      r,
      p,
      maxmem: 64 * 1024 * 1024,
    });
    return timingSafeEqual(candidate, expected);
  } catch {
    return false;
  }
}

export function issueAgentKey(): IssuedAgentKey {
  const credentialId = randomUUID();
  const secret = encodeBase64Url(randomBytes(32));
  return {
    credentialId,
    plaintext: `asi.${credentialId}.${secret}`,
    encodedHash: hashAgentSecret(secret),
  };
}

export function constantTimeTextEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  if (leftBytes.length !== rightBytes.length) {
    return false;
  }
  return timingSafeEqual(leftBytes, rightBytes);
}

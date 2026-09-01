import base64
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from uuid import UUID, uuid4


SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32


@dataclass(frozen=True)
class IssuedAgentKey:
    credential_id: UUID
    plaintext: str
    encoded_hash: str


def _b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _b64decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def issue_agent_key() -> IssuedAgentKey:
    credential_id = uuid4()
    secret = _b64encode(secrets.token_bytes(32))
    plaintext = f"asi.{credential_id}.{secret}"
    return IssuedAgentKey(
        credential_id=credential_id,
        plaintext=plaintext,
        encoded_hash=hash_agent_secret(secret),
    )


def parse_agent_key(value: str) -> tuple[UUID, str]:
    try:
        prefix, raw_id, secret = value.split(".", 2)
        credential_id = UUID(raw_id)
    except (ValueError, AttributeError) as exc:
        raise ValueError("invalid agent credential format") from exc
    if prefix != "asi" or len(secret) < 32:
        raise ValueError("invalid agent credential format")
    return credential_id, secret


def hash_agent_secret(secret: str) -> str:
    salt = secrets.token_bytes(16)
    derived = hashlib.scrypt(
        secret.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_DKLEN,
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${_b64encode(salt)}${_b64encode(derived)}"


def verify_agent_secret(secret: str, encoded_hash: str) -> bool:
    try:
        algorithm, raw_n, raw_r, raw_p, raw_salt, raw_expected = encoded_hash.split("$", 5)
        if algorithm != "scrypt":
            return False
        n, r, p = int(raw_n), int(raw_r), int(raw_p)
        if (n, r, p) != (SCRYPT_N, SCRYPT_R, SCRYPT_P):
            return False
        salt = _b64decode(raw_salt)
        expected = _b64decode(raw_expected)
        candidate = hashlib.scrypt(
            secret.encode("utf-8"),
            salt=salt,
            n=n,
            r=r,
            p=p,
            dklen=len(expected),
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(candidate, expected)


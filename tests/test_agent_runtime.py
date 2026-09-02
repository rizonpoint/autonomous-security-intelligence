import io
import json
import os
from pathlib import Path
from urllib.error import HTTPError

import pytest

from agent_runtime.cli import default_claim_file, lease_fields, sanitized_claim, write_private_json
from agent_runtime.client import ControlPlaneClient, ControlPlaneError, load_agent_key


TEST_KEY = "asi.00000000-0000-4000-8000-000000000000." + "x" * 43


class FakeResponse:
    def __init__(self, payload: object):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self) -> bytes:
        return self.payload


def test_key_loader_enforces_private_permissions(tmp_path: Path) -> None:
    key_file = tmp_path / "agent.key"
    key_file.write_text(TEST_KEY)
    os.chmod(key_file, 0o644)
    with pytest.raises(ControlPlaneError, match="0600"):
        load_agent_key(key_file)

    os.chmod(key_file, 0o600)
    assert load_agent_key(key_file) == TEST_KEY


def test_client_rejects_cleartext_remote_url() -> None:
    with pytest.raises(ControlPlaneError, match="HTTPS"):
        ControlPlaneClient(TEST_KEY, "http://example.com")


def test_claim_uses_bearer_auth_without_returning_key() -> None:
    captured = {}

    def opener(request, **_: object):
        captured["authorization"] = request.headers["Authorization"]
        captured["body"] = json.loads(request.data)
        return FakeResponse({"id": "work-1", "status": "claimed"})

    client = ControlPlaneClient(TEST_KEY, opener=opener)
    result = client.claim(120)

    assert captured["authorization"] == f"Bearer {TEST_KEY}"
    assert captured["body"] == {"lease_seconds": 120}
    assert TEST_KEY not in json.dumps(result)


def test_http_errors_are_sanitized() -> None:
    def opener(*_: object, **__: object):
        raise HTTPError(
            "https://example.test",
            401,
            "Unauthorized",
            {},
            io.BytesIO(b'{"detail":"invalid agent credential"}'),
        )

    client = ControlPlaneClient(TEST_KEY, opener=opener)
    with pytest.raises(ControlPlaneError, match="invalid agent credential") as caught:
        client.me()
    assert TEST_KEY not in str(caught.value)


def test_claim_is_saved_privately_and_sanitized(tmp_path: Path) -> None:
    claim = {
        "id": "work-1",
        "title": "Research ICP",
        "status": "claimed",
        "queue": "market-intelligence",
        "lease_token": "secret-lease",
        "lease_version": 2,
        "lease_expires_at": "2026-09-02T03:00:00Z",
        "trace_id": "trace-1",
    }
    claim_file = tmp_path / "market-intelligence.claim.json"

    write_private_json(claim_file, claim)
    summary = sanitized_claim(claim, claim_file)

    assert json.loads(claim_file.read_text()) == claim
    assert oct(claim_file.stat().st_mode & 0o777) == "0o600"
    assert summary["work_id"] == "work-1"
    assert "lease_token" not in summary
    assert "secret-lease" not in json.dumps(summary)


def test_claim_file_supplies_private_lease_fields(tmp_path: Path) -> None:
    claim_file = tmp_path / "market-intelligence.claim.json"
    write_private_json(
        claim_file,
        {"id": "work-1", "lease_token": "secret-lease", "lease_version": 3},
    )
    args = type(
        "Args",
        (),
        {
            "claim_file": str(claim_file),
            "work_item_id": None,
            "lease_token": None,
            "lease_version": None,
        },
    )()

    assert lease_fields(args) == ("work-1", "secret-lease", 3, claim_file)


def test_default_claim_file_is_scoped_to_agent_key() -> None:
    assert default_claim_file("~/.config/asi/agents/market-intelligence.key").name == (
        "market-intelligence.claim.json"
    )

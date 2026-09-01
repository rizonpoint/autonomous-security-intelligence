from control_plane_api.security import issue_agent_key, parse_agent_key, verify_agent_secret


def test_agent_key_round_trip_and_tamper_rejection() -> None:
    issued = issue_agent_key()
    credential_id, secret = parse_agent_key(issued.plaintext)

    assert credential_id == issued.credential_id
    assert verify_agent_secret(secret, issued.encoded_hash)
    assert not verify_agent_secret(secret + "tampered", issued.encoded_hash)
    assert secret not in issued.encoded_hash


def test_malformed_agent_key_is_rejected() -> None:
    for value in ("", "wrong", "asi.not-a-uuid.secret", "other.00000000-0000-0000-0000-000000000000.secret"):
        try:
            parse_agent_key(value)
        except ValueError:
            pass
        else:
            raise AssertionError(f"malformed key was accepted: {value}")


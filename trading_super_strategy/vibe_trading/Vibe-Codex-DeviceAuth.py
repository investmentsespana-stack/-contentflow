#!/usr/bin/env python
"""Vibe-owned OpenAI Codex device-code OAuth.

Uses OpenAI's device authorization flow but writes the resulting rotating
refresh credential directly to Vibe-Trading's canonical token storage.
It deliberately does NOT copy ~/.codex/auth.json, so Codex CLI and Vibe do
not share ownership of the same refresh token.
"""
from __future__ import annotations

import sys
import time
from typing import Any

import httpx

from oauth_cli_kit.models import OAuthToken
from oauth_cli_kit.pkce import _decode_account_id, _parse_token_payload
from src.providers.openai_codex import (
    _build_codex_token_storage,
    _load_codex_oauth_provider,
    get_openai_codex_login_status,
)

ISSUER = "https://auth.openai.com"
DEVICE_USERCODE_URL = f"{ISSUER}/api/accounts/deviceauth/usercode"
DEVICE_TOKEN_URL = f"{ISSUER}/api/accounts/deviceauth/token"
DEVICE_VERIFY_URL = f"{ISSUER}/codex/device"
DEVICE_REDIRECT_URI = f"{ISSUER}/deviceauth/callback"
MAX_WAIT_SECONDS = 15 * 60


def _existing_token_ready() -> bool:
    try:
        token = get_openai_codex_login_status()
    except Exception:
        return False
    return bool(
        token
        and getattr(token, "access", None)
        and getattr(token, "refresh", None)
        and getattr(token, "account_id", None)
    )


def _request_json(client: httpx.Client, url: str, *, json_body: dict[str, Any]) -> httpx.Response:
    response = client.post(url, json=json_body, headers={"Content-Type": "application/json"})
    return response


def main() -> int:
    if _existing_token_ready():
        print("VIBE_CODEX_DEVICE_AUTH=ALREADY_READY")
        print("OAUTH_READY=true")
        return 0

    provider = _load_codex_oauth_provider()
    storage = _build_codex_token_storage()

    with httpx.Client(timeout=30.0) as client:
        response = _request_json(
            client,
            DEVICE_USERCODE_URL,
            json_body={"client_id": provider.client_id},
        )
        if response.status_code != 200:
            raise RuntimeError(
                f"Device-code request failed: HTTP {response.status_code} {response.text[:500]}"
            )

        payload = response.json()
        device_auth_id = str(payload.get("device_auth_id") or "").strip()
        user_code = str(payload.get("user_code") or payload.get("usercode") or "").strip()
        try:
            interval = max(1, int(str(payload.get("interval") or "5").strip()))
        except ValueError:
            interval = 5
        if not device_auth_id or not user_code:
            raise RuntimeError("Device-code response missing required fields")

        print("")
        print("VIBE OPENAI CODEX DEVICE AUTH")
        print(f"OPEN_URL={DEVICE_VERIFY_URL}")
        print(f"ENTER_CODE={user_code}")
        print("The code expires in about 15 minutes.")
        print("Waiting for authorization...")

        started = time.monotonic()
        authorization_code = ""
        code_verifier = ""

        while time.monotonic() - started < MAX_WAIT_SECONDS:
            poll = _request_json(
                client,
                DEVICE_TOKEN_URL,
                json_body={
                    "device_auth_id": device_auth_id,
                    "user_code": user_code,
                },
            )
            if poll.status_code == 200:
                done = poll.json()
                authorization_code = str(done.get("authorization_code") or "").strip()
                code_verifier = str(done.get("code_verifier") or "").strip()
                if not authorization_code or not code_verifier:
                    raise RuntimeError("Device authorization completed but returned incomplete PKCE data")
                break
            if poll.status_code not in (403, 404):
                raise RuntimeError(
                    f"Device-code polling failed: HTTP {poll.status_code} {poll.text[:500]}"
                )
            time.sleep(interval)

        if not authorization_code:
            raise RuntimeError("Device authorization timed out after 15 minutes")

        exchange = client.post(
            provider.token_url,
            data={
                "grant_type": "authorization_code",
                "client_id": provider.client_id,
                "code": authorization_code,
                "code_verifier": code_verifier,
                "redirect_uri": DEVICE_REDIRECT_URI,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if exchange.status_code != 200:
            raise RuntimeError(
                f"Token exchange failed: HTTP {exchange.status_code} {exchange.text[:500]}"
            )

        access, refresh, expires_in = _parse_token_payload(
            exchange.json(),
            "Device token response missing fields",
        )
        account_id = _decode_account_id(
            access,
            provider.jwt_claim_path,
            provider.account_id_claim,
        )
        if not account_id:
            raise RuntimeError("Device token is missing ChatGPT account id")

        token = OAuthToken(
            access=access,
            refresh=refresh,
            expires=int(time.time() * 1000 + int(expires_in) * 1000),
            account_id=account_id,
        )
        storage.save(token)

    saved = storage.load()
    if not (
        saved
        and getattr(saved, "access", None)
        and getattr(saved, "refresh", None)
        and getattr(saved, "account_id", None)
    ):
        raise RuntimeError("Vibe OAuth token was not persisted")

    print("VIBE_CODEX_DEVICE_AUTH=PASS")
    print("OAUTH_READY=true")
    print(f"TOKEN_PATH={storage.get_token_path()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("VIBE_CODEX_DEVICE_AUTH=CANCELLED", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"VIBE_CODEX_DEVICE_AUTH=FAIL:{type(exc).__name__}:{exc}", file=sys.stderr)
        raise SystemExit(1)

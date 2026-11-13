import json

import pytest

from app.core.account_pool import Account, AccountStatus, account_pool
from test_detected_model_names import detected_client, model_entry

AUTH = {"Authorization": "Bearer sk-test-key"}
EXPECTED = ["gemini-3.1-pro", "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-4-argon"]


@pytest.fixture
def real_pool(gem_client, monkeypatch):
    client = detected_client(
        model_entry("e6fa609c3fa255c0", "3.1 Pro", 3),
        model_entry("56fdd199312815e2", "3.8 Flash", 1),
        model_entry("8c46e95b1a07cecc", "3.5 Flash-Lite", 6),
        model_entry("95a4c0abcba24364", "4 Argon", 8, "Argon"),
    )
    account = Account(id="actual", psid="test", psidts="", client=client, status=AccountStatus.ACTIVE)
    monkeypatch.setattr(account_pool, "_accounts", [account])
    return account


@pytest.mark.parametrize("path,field", [("/v1/models", "id"), ("/claude/v1/models", "id")])
def test_protocol_lists_use_actual_versions(gem_client, real_pool, path, field):
    body = gem_client.get(path, headers=AUTH).json()
    assert [model[field] for model in body["data"]] == EXPECTED


def test_native_list_uses_real_display_names(gem_client, real_pool):
    models = gem_client.get("/v1beta/models", headers=AUTH).json()["models"]
    assert [model["name"] for model in models] == [f"models/{name}" for name in EXPECTED]
    assert [model["display_name"] for model in models] == ["3.1 Pro", "3.8 Flash", "3.5 Flash-Lite", "4 Argon"]


def test_admin_returns_account_specific_model_metadata(gem_client, real_pool):
    account = gem_client.get("/admin/status", headers=AUTH).json()["accounts"][0]
    assert account["models"] == EXPECTED
    assert account["models_count"] == 4
    assert account["model_details"][0]["display_name"] == "3.1 Pro"
    assert account["model_details"][0]["model_id"] == "e6fa609c3fa255c0"


@pytest.mark.parametrize("name", ["gemini-pro", "gemini-flash", "gemini-argon", "gemini-2.5-pro", "gemini-flash-thinking"])
@pytest.mark.parametrize("protocol", ["chat", "responses", "claude", "gemini"])
def test_removed_aliases_are_rejected_by_each_protocol(gem_client, real_pool, name, protocol):
    if protocol == "chat":
        path, body = "/v1/chat/completions", {"model": name, "messages": [{"role": "user", "content": "hi"}]}
    elif protocol == "responses":
        path, body = "/v1/responses", {"model": name, "input": "hi"}
    elif protocol == "claude":
        path, body = "/v1/messages", {"model": name, "max_tokens": 64, "messages": [{"role": "user", "content": "hi"}]}
    else:
        path, body = f"/v1beta/models/{name}:generateContent", {"contents": [{"role": "user", "parts": [{"text": "hi"}]}]}
    response = gem_client.post(path, json=body, headers=AUTH)
    assert response.status_code == 400, response.text


@pytest.mark.parametrize("name", EXPECTED)
def test_detected_names_reach_the_actual_client(gem_client, real_pool, monkeypatch, name):
    captured = []

    async def send(prompt, model, conversation_id="", attachments=None, gem_id=None, extended_thinking=False):
        captured.append(model)
        return {"text": "ok", "images": [], "conversation_id": ""}

    monkeypatch.setattr(real_pool.client, "_send_request", send)
    response = gem_client.post("/v1/chat/completions", json={
        "model": name, "messages": [{"role": "user", "content": "hi"}],
    }, headers=AUTH)
    assert response.status_code == 200, response.text
    assert captured == [name]


def test_empty_account_pool_returns_empty_model_lists(gem_client, monkeypatch):
    monkeypatch.setattr(account_pool, "_accounts", [])
    assert gem_client.get("/v1/models", headers=AUTH).json()["data"] == []
    assert gem_client.get("/claude/v1/models", headers=AUTH).json()["data"] == []
    assert gem_client.get("/v1beta/models", headers=AUTH).json()["models"] == []

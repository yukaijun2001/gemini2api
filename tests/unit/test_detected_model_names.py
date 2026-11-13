import asyncio
import json

import pytest

from app.core import gemini_client as gc
from app.core.account_pool import Account, AccountPool, AccountStatus


def model_entry(model_id, display_name, number, category=None):
    entry = [None] * 20
    entry[0] = model_id
    entry[11] = display_name
    entry[17] = number
    entry[1] = category
    return entry


def status_response(*entries):
    body = [None] * 16
    body[15] = list(entries)
    return json.dumps([["wrb.fr", "otAQ7b", json.dumps(body)]])


def detected_client(*entries):
    client = gc.GeminiWebClient.__new__(gc.GeminiWebClient)
    client._healthy = True
    client._family_model = {}
    client._available_models = []
    client._discovered_models = {}
    client._parse_models_from_status(status_response(*entries))
    return client


def test_model_list_uses_upstream_versions_without_tier_backfill():
    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    assert client.models == ["gemini-3.1-pro"]
    assert set(client._model_table()) == {"gemini-3.1-pro"}
    assert client.model_details[0]["display_name"] == "3.1 Pro"
    assert client.model_details[0]["model_id"] == "e6fa609c3fa255c0"


def test_no_heartbeat_means_no_models_or_static_routing_table():
    client = gc.GeminiWebClient.__new__(gc.GeminiWebClient)
    client._available_models = []
    assert client.models == []
    assert client._model_table() == {}
    assert client.model_details == []


def test_empty_status_removes_previous_discoveries():
    client = detected_client(model_entry("56fdd199312815e2", "3.8 Flash", 1))
    client._parse_models_from_status(status_response())
    assert client.models == []
    assert client._model_table() == {}


def test_account_status_uses_each_accounts_own_models():
    pool = AccountPool()
    first = Account(id="pro", psid="first", psidts="", status=AccountStatus.ACTIVE)
    first.client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    second = Account(id="flash", psid="second", psidts="", status=AccountStatus.ACTIVE)
    second.client = detected_client(model_entry("56fdd199312815e2", "3.8 Flash", 1))
    pool._accounts = [first, second]
    accounts = pool.get_status()["accounts"]
    assert accounts[0]["models"] == ["gemini-3.1-pro"]
    assert accounts[1]["models"] == ["gemini-3.8-flash"]
    assert accounts[0]["models_count"] == accounts[1]["models_count"] == 1
    assert pool.models == ["gemini-3.1-pro", "gemini-3.8-flash"]


@pytest.mark.parametrize("name", ["gemini-pro", "gemini-2.5-pro", "gemini-3-pro-advanced"])
def test_legacy_names_cannot_route_to_a_discovered_model(name):
    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    with pytest.raises(gc.ModelUnavailable):
        asyncio.run(client.generate("hi", name))


def test_detected_name_builds_the_actual_wire_model_header():
    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    header = gc._build_model_header("gemini-3.1-pro", client._model_table())
    assert json.loads(header[gc.MODEL_HEADER_KEY])[4] == "e6fa609c3fa255c0"


@pytest.mark.parametrize("response", ["not JSON", "[[broken", "[]", "[[1, 2]]"])
def test_failed_parse_clears_previous_models(response):
    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    assert client._parse_models_from_status(response) is False
    assert client.models == []
    assert client.model_details == []


def test_failed_heartbeat_clears_previous_models(monkeypatch):
    from types import SimpleNamespace

    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    client._session_token = "test-token"

    async def noop(*args, **kwargs):
        return None

    async def post(*args, **kwargs):
        return SimpleNamespace(status_code=503)

    client._http = SimpleNamespace(post=post)
    client._cookie_jar = SimpleNamespace(update_from_response=lambda response: None)
    monkeypatch.setattr(gc, "apply_jitter", noop)
    monkeypatch.setattr(client, "_ensure_session_current", noop)
    monkeypatch.setattr(client, "_clear_session_cookies", lambda: None)
    monkeypatch.setattr(client, "_get_cookies", lambda: {})
    monkeypatch.setattr(client, "_get_headers", lambda *args, **kwargs: {})
    assert asyncio.run(client._send_heartbeat()) is False
    assert client.models == []


def test_failed_account_check_clears_previous_models(monkeypatch):
    from collections import deque
    from types import SimpleNamespace

    client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    client._check_history = deque(maxlen=20)

    async def noop(*args, **kwargs):
        return None

    async def get(*args, **kwargs):
        return SimpleNamespace(status_code=503)

    client._http = SimpleNamespace(get=get)
    client._cookie_jar = SimpleNamespace(update_from_response=lambda response: None)
    monkeypatch.setattr(client, "_ensure_session_current", noop)
    monkeypatch.setattr(client, "_clear_session_cookies", lambda: None)
    monkeypatch.setattr(client, "_get_cookies", lambda: {})
    monkeypatch.setattr(client, "_get_headers", lambda *args, **kwargs: {})
    result = asyncio.run(client.check_account())
    assert result["valid"] is False
    assert result["models_count"] == 0
    assert result["models"] == client.models == []


def test_default_model_uses_the_selected_accounts_detected_name():
    pool = AccountPool()
    first = Account(id="pro", psid="first", psidts="", status=AccountStatus.ACTIVE)
    first.client = detected_client(model_entry("e6fa609c3fa255c0", "3.1 Pro", 3))
    second = Account(id="flash", psid="second", psidts="", status=AccountStatus.ACTIVE)
    second.client = detected_client(model_entry("56fdd199312815e2", "3.8 Flash", 1))
    pool._accounts = [first, second]
    assert pool.default_model() == "gemini-3.1-pro"
    assert pool.default_model(account_id="flash") == "gemini-3.8-flash"
    with pytest.raises(gc.ModelUnavailable):
        pool.default_model(account_id="missing")

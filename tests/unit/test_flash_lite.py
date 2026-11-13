import json

from app.core import gemini_client as gc
from test_detected_model_names import detected_client, model_entry


def test_flash_lite_keeps_upstream_version_and_paid_id():
    client = detected_client(model_entry("8c46e95b1a07cecc", "3.5 Flash-Lite", 6))
    assert client.models == ["gemini-3.5-flash-lite"]
    table = client._model_table()
    header = json.loads(gc._build_model_header(client.models[0], table)[gc.MODEL_HEADER_KEY])
    assert header[4] == "8c46e95b1a07cecc"
    assert header[11] == 2
    assert gc._model_number(client.models[0], table) == 6


def test_flash_only_account_does_not_invent_flash_lite():
    client = detected_client(model_entry("fbb127bbb056c959", "3.8 Flash", 1))
    assert client.models == ["gemini-3.8-flash"]
    assert "flash-lite" not in client._family_model


def test_old_flash_lite_alias_is_not_resolved():
    assert gc._resolve_model("gemini-2.0-flash-lite") == "gemini-2.0-flash-lite"
    assert gc.MODEL_ALIASES == {}

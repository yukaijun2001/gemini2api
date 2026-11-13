import json

import pytest

from app.core import gemini_client as gc
from test_detected_model_names import detected_client, model_entry, status_response

PRO_ID = "e6fa609c3fa255c0"
ARGON_ID = "95a4c0abcba24364"


def test_all_families_keep_their_reported_versions():
    client = detected_client(
        model_entry(PRO_ID, "3.1 Pro", 3),
        model_entry("56fdd199312815e2", "3.8 Flash", 1),
        model_entry("8c46e95b1a07cecc", "3.5 Flash-Lite", 6),
        model_entry(ARGON_ID, "4 Argon", 8, "Argon"),
    )
    assert client.models == [
        "gemini-3.1-pro", "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-4-argon",
    ]
    table = client._model_table()
    header = json.loads(gc._build_model_header_thinking("gemini-4-argon", "SESSION", 1, table)[gc.MODEL_HEADER_KEY])
    assert header[4] == ARGON_ID
    assert header[11] == 2
    assert header[14] == 8


def test_unknown_model_is_listed_even_without_a_known_account_tier():
    client = detected_client(model_entry("0123456789abcdef", "5 Nova", 9, "Nova"))
    assert client.models == ["gemini-5-nova"]
    assert client.model_details[0]["display_name"] == "5 Nova"
    assert client.model_details[0]["routable"] is False
    assert client._model_table() == {}


def test_unknown_model_with_account_tier_can_be_routed():
    client = detected_client(
        model_entry(PRO_ID, "3.1 Pro", 3),
        model_entry("0123456789abcdef", "5 Nova", 9, "Nova"),
    )
    info = client._model_table()["gemini-5-nova"]
    assert info["capacity"] == 2
    assert info["model_number"] == 9
    assert gc.model_family("gemini-5-nova", [client]) == "nova"


def test_multiple_models_in_one_family_are_not_collapsed():
    client = detected_client(
        model_entry(PRO_ID, "3.1 Pro", 3),
        model_entry("9d8ca3786ebdfbea", "3 Pro", 3),
    )
    assert client.models == ["gemini-3.1-pro", "gemini-3-pro"]


@pytest.mark.parametrize("model_id", ["short", "A" * 16, "z" * 16, 123, None])
def test_malformed_ids_are_rejected(model_id):
    assert detected_client(model_entry(model_id, "5 Nova", 9)).models == []


@pytest.mark.parametrize("display", [None, "", " " * 4, "x" * 161, "5 Nova\nInjected"])
def test_invalid_display_names_are_rejected(display):
    assert detected_client(model_entry("0123456789abcdef", display, 9)).models == []


@pytest.mark.parametrize("number", [None, False, True, 0, -1, "9"])
def test_unknown_model_missing_valid_number_is_visible_but_not_routable(number):
    client = detected_client(
        model_entry(PRO_ID, "3.1 Pro", 3),
        model_entry("0123456789abcdef", "5 Nova", number, "Nova"),
    )
    assert "gemini-5-nova" in client.models
    assert "gemini-5-nova" not in client._model_table()


def test_models_disappear_when_the_next_heartbeat_no_longer_reports_them():
    client = detected_client(model_entry(ARGON_ID, "4 Argon", 8, "Argon"))
    client._parse_models_from_status(status_response(model_entry(PRO_ID, "3.1 Pro", 3)))
    assert client.models == ["gemini-3.1-pro"]
    assert "gemini-4-argon" not in client._model_table()


def test_repeated_heartbeats_replace_the_table_instead_of_accumulating_models():
    client = detected_client()
    for number in range(40):
        client._parse_models_from_status(status_response(
            model_entry(f"{number:016x}", f"{number} Nova", 9, "Nova"),
        ))
    assert client.models == ["gemini-39-nova"]


def test_flood_is_bounded_and_duplicates_do_not_overwrite_model_ids():
    entries = [model_entry(f"{number:016x}", f"5 Nova {number}", 9) for number in range(300)]
    assert len(detected_client(*entries).models) == gc._DISCOVER_MAX_TOTAL
    client = detected_client(
        model_entry("0123456789abcdef", "5 Nova", 9),
        model_entry("abcdef0123456789", "5 Nova", 9),
    )
    assert len(client.models) == 2
    assert {info["model_id"] for info in client.model_details} == {"0123456789abcdef", "abcdef0123456789"}


def test_non_status_rpc_cannot_replace_the_models():
    raw = status_response(model_entry(PRO_ID, "3.1 Pro", 3)).replace("otAQ7b", "otherRpc")
    client = detected_client()
    assert client._parse_models_from_status(raw) is False
    assert client.models == []

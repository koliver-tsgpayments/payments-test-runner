import logging
from unittest.mock import MagicMock, patch

import pytest

from functions.processors import tsg, worldpay


@pytest.fixture(autouse=True)
def _set_env(monkeypatch):
    monkeypatch.setenv("ENV", "test")
    monkeypatch.setenv("REGION", "test-region")


@patch("functions.processors._runner.requests.get")
def test_run_tsgpayments_success(mock_get, caplog):
    mock_get.return_value = MagicMock(status_code=200)

    with caplog.at_level(logging.INFO):
        result = tsg.run_tsgpayments({}, None)

    assert result["processor"] == "tsgpayments"
    assert result["ok"] is True
    assert result["status_code"] == 200
    assert "error" not in result
    assert '"processor": "tsgpayments"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_tsgpayments_failure(mock_get, caplog):
    mock_get.side_effect = RuntimeError("boom")

    with caplog.at_level(logging.ERROR):
        result = tsg.run_tsgpayments({}, None)

    assert result["ok"] is False
    assert result["status_code"] is None
    assert result["error"] == "boom"
    assert '"processor": "tsgpayments"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_worldpay_success(mock_get, caplog):
    mock_get.return_value = MagicMock(status_code=302)

    with caplog.at_level(logging.INFO):
        result = worldpay.run_worldpay({}, None)

    assert result["processor"] == "worldpay"
    assert result["ok"] is True
    assert result["status_code"] == 302
    assert "error" not in result
    assert '"processor": "worldpay"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_worldpay_failure(mock_get, caplog):
    mock_get.side_effect = RuntimeError("bad news")

    with caplog.at_level(logging.ERROR):
        result = worldpay.run_worldpay({}, None)

    assert result["ok"] is False
    assert result["status_code"] is None
    assert result["error"] == "bad news"
    assert '"processor": "worldpay"' in caplog.text

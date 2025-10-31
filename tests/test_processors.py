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
    # Envelope logs contain target in event.target
    assert '"target":"tsgpayments"' in caplog.text or '"target": "tsgpayments"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_tsgpayments_failure(mock_get, caplog):
    mock_get.side_effect = RuntimeError("boom")

    with caplog.at_level(logging.ERROR):
        with pytest.raises(RuntimeError):
            tsg.run_tsgpayments({}, None)

    # Look for the envelope with target + ERROR status
    assert '"target":"tsgpayments"' in caplog.text or '"target": "tsgpayments"' in caplog.text
    assert '"status":"ERROR"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_worldpay_success(mock_get, caplog):
    mock_get.return_value = MagicMock(status_code=302)

    with caplog.at_level(logging.INFO):
        result = worldpay.run_worldpay({}, None)

    assert result["processor"] == "worldpay"
    assert result["ok"] is True
    assert result["status_code"] == 302
    assert "error" not in result
    assert '"target":"worldpay"' in caplog.text or '"target": "worldpay"' in caplog.text


@patch("functions.processors._runner.requests.get")
def test_run_worldpay_failure(mock_get, caplog):
    mock_get.side_effect = RuntimeError("bad news")

    with caplog.at_level(logging.ERROR):
        with pytest.raises(RuntimeError):
            worldpay.run_worldpay({}, None)

    assert '"target":"worldpay"' in caplog.text or '"target": "worldpay"' in caplog.text
    assert '"status":"ERROR"' in caplog.text

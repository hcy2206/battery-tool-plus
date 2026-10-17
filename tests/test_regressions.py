"""Regression tests use only the file-backed C backend, including subprocesses."""
import json
import os
import signal
import time
import subprocess
import sys
from pathlib import Path

import pytest
from typer.testing import CliRunner

from batterytool.battery import BatteryControlError, legacy_enable_charging, tahoe_enable_charging, ffi, lib
from batterytool.logging import setup_logging
from batterytool.loop import legacy_loop, tahoe_loop
from batterytool.main import app
from tests.conftest import LEGACY_KEYS, TAHOE_KEYS


@pytest.mark.parametrize("args", [
    ["--interval", "0"], ["--interval", "-1"], ["--target-health", "101"],
    ["--min-charge", "0"], ["--min-charge", "95", "--max-charge", "95"],
    ["--max-charge", "101"],
])
def test_invalid_cli_options_never_write(hw, args):
    result = CliRunner().invoke(app, args)
    assert result.exit_code == 2
    assert hw.writes() == ()


@pytest.mark.apple_silicon
def test_installed_command_parses_status_and_log_file(hw, tmp_path):
    hw.script((80, 100, 100, 10, 1, 0))
    logfile = tmp_path / "status.jsonl"
    result = subprocess.run(
        [str(Path(sys.executable).with_name("battery-tool")), "--status", "--log-file", str(logfile)],
        env=os.environ.copy(), capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(logfile.read_text())["event"] == "battery_status"
    assert hw.writes() == ()


@pytest.mark.apple_silicon
@pytest.mark.parametrize("row", [(0, 0, 0, 0, 0, 0), (50, 100, 100, 10, 0, 0)])
def test_cli_startup_errors_exit_nonzero(hw, row):
    hw.script(row)
    assert CliRunner().invoke(app, []).exit_code == 1
    assert hw.writes() == ()


@pytest.mark.parametrize("loop,keys,disable,enable", [
    (legacy_loop, LEGACY_KEYS, ("CH0B=02", "CH0C=02", "CH0I=01"), ("CH0B=00", "CH0C=00", "CH0I=00")),
    (tahoe_loop, TAHOE_KEYS, ("CHTE=01000000", "CHIE=08"), ("CHTE=00000000", "CHIE=00")),
])
def test_exact_thresholds_switch_and_disconnect_restores(hw, loop, keys, disable, enable):
    hw.set_keys(keys)
    hw.script((95, 100, 100, 10, 1, 1), (5, 100, 100, 10, 0, 1), (50, 100, 100, 10, 0, 0))
    assert loop(79, 95, 5, 0, setup_logging()) is False
    assert hw.writes() == disable + enable + enable


@pytest.mark.parametrize("loop,keys,enable", [
    (legacy_loop, LEGACY_KEYS, ("CH0B=00", "CH0C=00", "CH0I=00")),
    (tahoe_loop, TAHOE_KEYS, ("CHTE=00000000", "CHIE=00")),
])
def test_startup_restores_unknown_charging_state(hw, loop, keys, enable):
    hw.set_keys(keys)
    hw.script((50, 100, 100, 10, 0, 1), (79, 79, 100, 10, 1, 1))
    assert loop(79, 95, 5, 0, setup_logging()) is True
    assert hw.writes() == enable + enable


def test_failed_write_stops_without_false_success_and_attempts_cleanup(hw, capfd):
    hw.set_keys({"CH0B": "00", "CH0I": "00"})  # CH0C write fails
    hw.script((96, 100, 100, 10, 1, 1))
    assert legacy_loop(79, 95, 5, 0, setup_logging()) is False
    assert hw.writes() == ("CH0B=02", "CH0B=00", "CH0I=00")
    events = [json.loads(line)["event"] for line in capfd.readouterr().err.splitlines()]
    assert "charging_disabled" not in events
    assert "unexpected_error" in events
    assert "cleanup_failed" in events


@pytest.mark.parametrize("enable,keys,writes", [
    (legacy_enable_charging, {"CH0C": "02", "CH0I": "01"}, ("CH0C=00", "CH0I=00")),
    (tahoe_enable_charging, {"CH0J": "01"}, ("CH0J=00",)),
])
def test_cleanup_attempts_remaining_keys_after_failure(hw, enable, keys, writes):
    hw.set_keys(keys)
    with pytest.raises(BatteryControlError):
        enable()
    assert hw.writes() == writes


def test_repeated_logging_setup_does_not_duplicate(hw, capfd):
    setup_logging()
    setup_logging().info("once")
    assert len(capfd.readouterr().err.splitlines()) == 1


@pytest.mark.parametrize("value", [b"0", b"000", b"zz", b"", b"00" * 33])
def test_c_wrapper_rejects_invalid_hex(hw, value):
    hw.set_keys(LEGACY_KEYS)
    assert lib.SmcWriteKey(b"CH0B", value) == -1
    assert hw.writes() == ()


def test_c_wrapper_rejects_invalid_buffers_and_keys(hw):
    hw.set_keys(LEGACY_KEYS)
    assert lib.SmcReadKey(b"CH0B", ffi.new("char[32]"), -1) == -1
    assert lib.SmcWriteKey(b"CH0Bextra", b"00") == -1
    assert hw.writes() == ()


@pytest.mark.apple_silicon
def test_installed_command_ctrl_c_restores_charging(hw, tmp_path):
    hw.set_keys(LEGACY_KEYS)
    hw.script((96, 100, 100, 10, 1, 1))
    logfile = tmp_path / "cycle.jsonl"
    process = subprocess.Popen(
        [str(Path(sys.executable).with_name("battery-tool")), "--log-file", str(logfile)],
        env=os.environ.copy(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        deadline = time.monotonic() + 10
        while not logfile.exists() or '"charging_disabled"' not in logfile.read_text():
            assert process.poll() is None, "Command exited before disabling charging"
            assert time.monotonic() < deadline, "Timed out waiting for cycle startup"
            time.sleep(0.02)
        process.send_signal(signal.SIGINT)
        _, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        assert hw.writes()[-3:] == ("CH0B=00", "CH0C=00", "CH0I=00")
        events = [json.loads(line)["event"] for line in logfile.read_text().splitlines()]
        assert "keyboard_interrupt" in events
        assert "cleanup_failed" not in events
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)


@pytest.mark.apple_silicon
def test_cli_reports_cleanup_failure(hw):
    hw.set_keys({"CH0B": "00"})
    hw.script((79, 79, 100, 10, 1, 1))
    result = CliRunner().invoke(app, [])
    assert result.exit_code == 1
    assert "cleanup_failed" in result.output

"""Controllers must not issue competing SMC writes."""

import pytest

from batterytool import locking


def test_real_controller_lock_rejects_second_owner_and_releases(tmp_path, monkeypatch):
    monkeypatch.delenv("BATTERYTOOL_FAKE", raising=False)
    monkeypatch.setattr(locking.os, "geteuid", lambda: 0)
    monkeypatch.setattr(locking, "CONTROL_LOCK", str(tmp_path / "control.lock"))
    with locking.hardware_lock():
        with pytest.raises(RuntimeError, match="already running"):
            with locking.hardware_lock():
                pytest.fail("Second owner acquired the lock")
    with locking.hardware_lock():
        pass


def test_fake_backend_does_not_touch_system_lock(tmp_path, monkeypatch):
    path = tmp_path / "nonexistent" / "control.lock"
    monkeypatch.setattr(locking, "CONTROL_LOCK", str(path))
    monkeypatch.setenv("BATTERYTOOL_FAKE", "1")
    with locking.hardware_lock():
        pass
    assert not path.exists()


def test_lock_refuses_symlink(tmp_path, monkeypatch):
    monkeypatch.delenv("BATTERYTOOL_FAKE", raising=False)
    monkeypatch.setattr(locking.os, "geteuid", lambda: 0)
    target = tmp_path / "target"
    target.write_text("unchanged")
    link = tmp_path / "lock"
    link.symlink_to(target)
    monkeypatch.setattr(locking, "CONTROL_LOCK", str(link))
    with pytest.raises(OSError):
        with locking.hardware_lock():
            pytest.fail("Followed a symlink")
    assert target.read_text() == "unchanged"


def test_real_controller_requires_root(tmp_path, monkeypatch):
    monkeypatch.delenv("BATTERYTOOL_FAKE", raising=False)
    monkeypatch.setattr(locking.os, "geteuid", lambda: 501)
    path = tmp_path / "control.lock"
    monkeypatch.setattr(locking, "CONTROL_LOCK", str(path))
    with pytest.raises(RuntimeError, match="sudo"):
        with locking.hardware_lock():
            pytest.fail("Acquired the hardware lock without root")
    assert not path.exists()

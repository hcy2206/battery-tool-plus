"""Coordinate the legacy CLI with the native application's power helper."""

import fcntl
import os
from collections.abc import Iterator
from contextlib import contextmanager

CONTROL_LOCK = "/var/run/batterytool-control.lock"


@contextmanager
def hardware_lock() -> Iterator[None]:
    """Allow only one real battery controller; fake tests never acquire system locks."""
    if os.environ.get("BATTERYTOOL_FAKE"):
        yield
        return
    if os.geteuid() != 0:
        raise RuntimeError("Battery control writes SMC keys and needs root: run with sudo")
    descriptor = os.open(CONTROL_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Another BatteryTool controller is already running") from exc
        yield
    finally:
        os.close(descriptor)

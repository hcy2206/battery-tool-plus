import os
import subprocess
import time
from collections.abc import Callable

import structlog

from batterytool.battery import (
    adapter_disable_charging,
    adapter_enable_charging,
    battery_reading,
    fetch_battery_info,
    legacy_disable_charging,
    legacy_enable_charging,
    tahoe_disable_charging,
    tahoe_enable_charging,
)

# Charging permitted but absent for this long means macOS holds its own charge
# limit (80 % limit / optimized charging) below max_charge; no firmware key
# overrides it, so that level becomes the top of the cycle
CHARGE_STALL_SECONDS = 600


class SleepHold:
    """Keep the Mac awake while the adapter is cut.

    On battery, macOS sleeps within seconds with the lid closed and after the
    battery idle timer otherwise, which ends the discharge phase. Power
    assertions do not stop clamshell sleep, so system sleep is switched off
    (``pmset disablesleep 1``) for the discharge phase only and restored
    afterwards. A user who already disabled sleep is left alone.
    """

    # Re-enabling sleep the instant the adapter is restored runs the clamshell sleep raised
    # while it was away, so the release waits for IOKit to see the adapter, then settles
    SETTLE_SECONDS = 20.0

    def __init__(
        self,
        run: Callable[..., object] | None = None,
        enabled: bool | None = None,
        settle: Callable[[], None] | None = None,
        user_disabled: bool | None = None,
    ):
        self._run = run or subprocess.run
        self._enabled = (not os.environ.get("BATTERYTOOL_FAKE")) if enabled is None else enabled
        self._settle = settle or self._wait_for_adapter
        self._held = False
        if user_disabled is None:
            user_disabled = self._enabled and self._registry_flag("IOPMrootDomain", "SleepDisabled")
        self._user_disabled = user_disabled

    @staticmethod
    def _registry_flag(service: str, key: str) -> bool:
        try:
            result = subprocess.run(
                ["/usr/sbin/ioreg", "-rn", service, "-d", "1"],
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return any(f'"{key}" = Yes' in line for line in result.stdout.splitlines())

    def _wait_for_adapter(self) -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not self._registry_flag("AppleSmartBattery", "ExternalConnected"):
            time.sleep(0.25)
        time.sleep(self.SETTLE_SECONDS)

    def _pmset(self, disable: bool) -> None:
        self._run(["/usr/bin/pmset", "disablesleep", "1" if disable else "0"], check=True, timeout=10)

    def hold(self) -> None:
        """Disable system sleep for the discharge phase (idempotent)."""
        if self._held or not self._enabled or self._user_disabled:
            return
        self._pmset(True)
        self._held = True

    def release(self, settled: bool = True) -> None:
        """Restore system sleep if this hold disabled it; settled waits for the adapter first."""
        if not self._held:
            return
        if settled:
            self._settle()
        self._pmset(False)
        self._held = False


class DisplayHold:
    """Keep the display awake for the whole cycle.

    With the lid closed, macOS lights an external display only while external
    power is present; during a discharge the cut adapter does not count, so a
    display that idled off stays dark until charging resumes. ``caffeinate -d``
    tied to this process holds a prevent-display-sleep assertion; it exits with
    the loop or, via ``-w``, if the loop dies.
    """

    def __init__(self, enabled: bool | None = None):
        self._enabled = (not os.environ.get("BATTERYTOOL_FAKE")) if enabled is None else enabled
        self._process: subprocess.Popen[bytes] | None = None

    def hold(self) -> None:
        """Start caffeinate unless already running or disabled."""
        if not self._enabled or self._process is not None:
            return
        try:
            self._process = subprocess.Popen(
                ["/usr/bin/caffeinate", "-d", "-w", str(os.getpid())],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            self._process = None

    def release(self) -> None:
        """Stop caffeinate so the display may sleep again."""
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
        self._process = None


def _cycle_loop(
    target_health: int,
    max_charge: int,
    min_charge: int,
    interval: int,
    logger: structlog.stdlib.BoundLogger,
    enable_charging: Callable[[], None],
    disable_charging: Callable[[], None],
    sleep_hold: SleepHold | None = None,
    display_hold: DisplayHold | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> bool:
    charging_enabled: bool | None = None
    stall_since: float | None = None
    stall_level = 0.0
    sleep_hold = sleep_hold or SleepHold()
    display_hold = display_hold or DisplayHold()

    success = True
    display_hold.hold()
    try:
        while True:
            battery_info = fetch_battery_info()

            if battery_info.max_capacity <= 0 or battery_info.design_capacity <= 0:
                logger.error("invalid_battery_data", message="Failed to read valid battery capacity from IOKit")
                success = False
                break

            battery_percentage, battery_health = battery_reading(battery_info)

            logger.info(
                "battery_reading",
                battery_percentage=battery_percentage,
                battery_health=battery_health,
                current_capacity=battery_info.current_capacity,
                max_capacity=battery_info.max_capacity,
                design_capacity=battery_info.design_capacity,
                cycle_count=battery_info.cycle_count,
                is_charging=battery_info.is_charging,
                is_plugged_in=battery_info.is_plugged_in,
                charging_enabled=charging_enabled,
            )

            if battery_health <= target_health:
                logger.info(
                    "target_reached",
                    target_health=target_health,
                    current_health=battery_health,
                )
                break

            if not battery_info.is_plugged_in:
                logger.error("charger_disconnected")
                success = False
                break

            if charging_enabled and not battery_info.is_charging and battery_percentage < max_charge:
                if stall_since is None or battery_percentage > stall_level + 0.5:
                    stall_since, stall_level = clock(), battery_percentage
            else:
                stall_since = None
            stalled = stall_since is not None and clock() - stall_since >= CHARGE_STALL_SECONDS

            if (battery_percentage >= max_charge or stalled) and charging_enabled is not False:
                # Hold sleep before the adapter is cut; drop it again if the cut fails
                sleep_hold.hold()
                try:
                    disable_charging()
                except Exception:
                    sleep_hold.release(settled=False)
                    raise
                logger.info("charging_disabled", battery_percentage=battery_percentage, stalled=stalled)
                charging_enabled = False
            elif charging_enabled is None or (battery_percentage <= min_charge and not charging_enabled):
                enable_charging()
                sleep_hold.release()
                logger.info("charging_enabled", battery_percentage=battery_percentage)
                charging_enabled = True

            logger.debug("sleeping", interval=interval)
            time.sleep(interval)
    except KeyboardInterrupt:
        logger.info("keyboard_interrupt")
    except Exception as e:
        success = False
        logger.exception("unexpected_error", error=str(e))
    finally:
        logger.info("cleanup", action="re-enabling charging")
        try:
            enable_charging()
        except Exception as e:
            success = False
            logger.exception("cleanup_failed", error=str(e))
        try:
            sleep_hold.release()
        except Exception as e:
            success = False
            logger.exception("sleep_restore_failed", error=str(e))
        display_hold.release()
    return success


def legacy_loop(
    target_health: int,
    max_charge: int,
    min_charge: int,
    interval: int,
    logger: structlog.stdlib.BoundLogger,
) -> bool:
    """Cycle using legacy SMC keys; return whether operation and cleanup succeeded."""
    return _cycle_loop(
        target_health,
        max_charge,
        min_charge,
        interval,
        logger,
        legacy_enable_charging,
        legacy_disable_charging,
    )


def tahoe_loop(
    target_health: int,
    max_charge: int,
    min_charge: int,
    interval: int,
    logger: structlog.stdlib.BoundLogger,
) -> bool:
    """Cycle using tahoe SMC keys; return whether operation and cleanup succeeded."""
    return _cycle_loop(
        target_health,
        max_charge,
        min_charge,
        interval,
        logger,
        tahoe_enable_charging,
        tahoe_disable_charging,
    )


def adapter_loop(
    target_health: int,
    max_charge: int,
    min_charge: int,
    interval: int,
    logger: structlog.stdlib.BoundLogger,
) -> bool:
    """Cycle by cutting and restoring the adapter (CHIE only); return whether operation and cleanup succeeded."""
    return _cycle_loop(
        target_health,
        max_charge,
        min_charge,
        interval,
        logger,
        adapter_enable_charging,
        adapter_disable_charging,
    )

"""
SMC Learnings

The System Management Controller (SMC) controls most power functions on modern Macs
Battery charging is one of the functions controlled by the SMC. By manipulating the SMC keys,
I can control battery charging on the Mac

I found a good discussion on the SMC keys that control battery charging
on this GitHub issue: https://github.com/zackelia/bclm/issues/20

Legacy keys (pre-macOS 15.7):

  CH0I/CH0C are "hard" controls that will allow the battery to run down to 0
  CH0K/CH0B are "soft" controls that are reset to 0 when SOC drops below 50%

  CH0B and CH0C are used to control whether the SMC permits charging
      - Writing "00" to CH0B & CH0C tells the SMC to allow or resume charging
      - Writing "02" to CH0B & CH0C tells the SMC to disable or block charging

  CH0I controls whether the Mac will force battery discharge even when it's plugged in
      - Writing "00" to CH0I disables discharge
      - Writing "01" to CH0I enables discharge

Tahoe keys (macOS 15.7+):

  Apple's firmware update replaced the legacy keys with a new set
  See: https://github.com/actuallymentor/battery/pull/388

  CHTE replaces CH0B/CH0C for charging control
      - Writing "00000000" to CHTE enables charging
      - Writing "01000000" to CHTE disables charging

  For forced discharge, there are now two keys with a fallback chain:
      CHIE is preferred (replaces CH0I)
          - Writing "00" to CHIE disables discharge
          - Writing "08" to CHIE enables discharge
      CH0J is the fallback if CHIE is unavailable
          - Writing "00" to CH0J disables discharge
          - Writing "01" to CH0J enables discharge

  Not all Tahoe machines expose the same keys. I detect which keys
  are available at runtime by attempting to read each one

Adapter-only firmware (macOS 27, and the firmware shipped with 15.8 / 26.7):

  CHTE, CH0B and CH0C are gone and their replacements (bfD0/bfE0/bfF0) are
  entitlement-gated even for root. CHIE still works, and cutting the adapter
  is what drives the discharge phase anyway, so cycling runs on CHIE alone.
"""

import json
import os
import platform
import subprocess
from typing import TYPE_CHECKING

from batterytool.constants import SMCKeys, SMCValues

if TYPE_CHECKING:
    from batterytool.iokit_wrapper import BatteryInfo

# BATTERYTOOL_FAKE swaps in the file-backed fake backend (see c/smc_fake.c),
# so the whole package can run in tests/CI/VMs without touching the SMC
if os.environ.get("BATTERYTOOL_FAKE"):
    from batterytool.iokit_wrapper_fake import ffi, lib
else:
    from batterytool.iokit_wrapper import ffi, lib


def fetch_battery_info():
    """Fetch current battery info from IOKit via CFFI"""
    return lib.FetchBatteryInfo()


def system_battery_health() -> float | None:
    """The "Maximum Capacity" percentage shown in System Settings.

    powerd computes it with its own filtered algorithm and only hands it to
    callers holding a private entitlement; ``system_profiler`` is such a
    caller, so its JSON output is the one public route to the same number.
    Returns None when unavailable (including under the fake backend).
    """
    if os.environ.get("BATTERYTOOL_FAKE"):
        return None
    try:
        output = subprocess.run(
            ["/usr/sbin/system_profiler", "SPPowerDataType", "-json"],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        ).stdout
        for entry in json.loads(output).get("SPPowerDataType", []):
            text = entry.get("sppower_battery_health_info", {}).get("sppower_battery_health_maximum_capacity")
            if isinstance(text, str) and text.endswith("%"):
                value = float(text[:-1])
                if 0 < value <= 100:
                    return value
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return None


def battery_reading(info: "BatteryInfo") -> tuple[float, float]:
    """(percentage, health) as macOS displays them.

    Percentage is the gauge state of charge (menu bar / pmset); health is the
    System Settings figure when readable, else nominal / design capacity. The
    caller has already checked that max and design capacity are positive.
    """
    percentage = info.current_capacity / info.max_capacity * 100
    if 0 <= info.state_of_charge <= 100:
        percentage = float(info.state_of_charge)
    health = system_battery_health()
    if health is None:
        health = info.max_capacity / info.design_capacity * 100
    return percentage, health


def is_apple_silicon() -> bool:
    """Check if I'm running on an Apple Silicon Mac"""
    return platform.machine() == "arm64"


def _key_exists(key: SMCKeys) -> bool:
    buf = ffi.new("char[32]")
    return lib.SmcReadKey(key, buf, 32) == 0


def is_tahoe() -> bool:
    """Check if I'm on a Tahoe mac (macOS 15.7+) by trying to read the CHTE key"""
    return _key_exists(SMCKeys.CHARGING_CONTROL_TE)


def detect_charge_control() -> str:
    """Name the key set this firmware exposes: tahoe, legacy, adapter or none."""
    if is_tahoe():
        return "tahoe"
    if _key_exists(SMCKeys.CHARGING_CONTROL_B):
        return "legacy"
    if _key_exists(SMCKeys.DISCHARGE_CONTROL_IE):
        return "adapter"
    return "none"


class BatteryControlError(RuntimeError):
    """One or more SMC writes failed."""


def _write_keys(writes: tuple[tuple[SMCKeys, SMCValues], ...], *, best_effort: bool = False) -> None:
    failed: list[str] = []
    for key, value in writes:
        if lib.SmcWriteKey(key, value) != 0:
            failed.append(key.decode())
            if not best_effort:
                break
    if failed:
        raise BatteryControlError(f"Failed to write SMC keys: {', '.join(failed)}")


# Legacy (pre-macOS 15.7)


def legacy_disable_charging() -> None:
    """Disable charging and force discharge via CH0B/CH0C/CH0I"""
    _write_keys(
        (
            (SMCKeys.CHARGING_CONTROL_B, SMCValues.DISABLE_CHARGING),
            (SMCKeys.CHARGING_CONTROL_C, SMCValues.DISABLE_CHARGING),
            (SMCKeys.DISCHARGE_CONTROL_I, SMCValues.ENABLE_DISCHARGE),
        )
    )


def legacy_enable_charging() -> None:
    """Attempt every restoration write, even if an earlier write fails."""
    _write_keys(
        (
            (SMCKeys.CHARGING_CONTROL_B, SMCValues.ENABLE_CHARGING),
            (SMCKeys.CHARGING_CONTROL_C, SMCValues.ENABLE_CHARGING),
            (SMCKeys.DISCHARGE_CONTROL_I, SMCValues.DISABLE_DISCHARGE),
        ),
        best_effort=True,
    )


def _tahoe_set_charging(*, enabled: bool) -> None:
    charging = SMCValues.TAHOE_ENABLE_CHARGING if enabled else SMCValues.TAHOE_DISABLE_CHARGING
    discharge = SMCValues.TAHOE_DISABLE_DISCHARGE if enabled else SMCValues.TAHOE_ENABLE_DISCHARGE
    fallback = SMCValues.TAHOE_FALLBACK_DISABLE_DISCHARGE if enabled else SMCValues.TAHOE_FALLBACK_ENABLE_DISCHARGE
    failed: list[str] = []
    if lib.SmcWriteKey(SMCKeys.CHARGING_CONTROL_TE, charging) != 0:
        failed.append("CHTE")
        if not enabled:
            raise BatteryControlError("Failed to write SMC key: CHTE")
    if (
        lib.SmcWriteKey(SMCKeys.DISCHARGE_CONTROL_IE, discharge) != 0
        and lib.SmcWriteKey(SMCKeys.DISCHARGE_CONTROL_J, fallback) != 0
    ):
        failed.append("CHIE/CH0J")
    if failed:
        raise BatteryControlError(f"Failed to write SMC keys: {', '.join(failed)}")


def tahoe_disable_charging() -> None:
    """Disable charging and force discharge, with CH0J fallback."""
    _tahoe_set_charging(enabled=False)


def tahoe_enable_charging() -> None:
    """Attempt both charging and discharge restoration, with CH0J fallback."""
    _tahoe_set_charging(enabled=True)


# Adapter-only firmware (no charge-inhibit key; CHIE drives both phases)


def adapter_disable_charging() -> None:
    """Cut the adapter via CHIE so the battery discharges."""
    _write_keys(((SMCKeys.DISCHARGE_CONTROL_IE, SMCValues.TAHOE_ENABLE_DISCHARGE),))


def adapter_enable_charging() -> None:
    """Restore the adapter via CHIE so the battery charges normally."""
    _write_keys(((SMCKeys.DISCHARGE_CONTROL_IE, SMCValues.TAHOE_DISABLE_DISCHARGE),))

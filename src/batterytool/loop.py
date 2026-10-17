import time
from collections.abc import Callable

import structlog

from batterytool.battery import (
    fetch_battery_info,
    legacy_disable_charging,
    legacy_enable_charging,
    tahoe_disable_charging,
    tahoe_enable_charging,
)


def _cycle_loop(
    target_health: int,
    max_charge: int,
    min_charge: int,
    interval: int,
    logger: structlog.stdlib.BoundLogger,
    enable_charging: Callable[[], None],
    disable_charging: Callable[[], None],
) -> bool:
    charging_enabled: bool | None = None

    success = True
    try:
        while True:
            battery_info = fetch_battery_info()

            if battery_info.max_capacity <= 0 or battery_info.design_capacity <= 0:
                logger.error("invalid_battery_data", message="Failed to read valid battery capacity from IOKit")
                success = False
                break

            battery_percentage = battery_info.current_capacity / battery_info.max_capacity * 100
            battery_health = battery_info.max_capacity / battery_info.design_capacity * 100

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

            if battery_percentage >= max_charge and charging_enabled is not False:
                disable_charging()
                logger.info("charging_disabled", battery_percentage=battery_percentage)
                charging_enabled = False
            elif charging_enabled is None or (battery_percentage <= min_charge and not charging_enabled):
                enable_charging()
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

from pathlib import Path
from typing import TYPE_CHECKING, Annotated

import typer

from batterytool.battery import detect_charge_control, fetch_battery_info, is_apple_silicon
from batterytool.locking import hardware_lock
from batterytool.logging import setup_logging
from batterytool.loop import adapter_loop, legacy_loop, tahoe_loop

if TYPE_CHECKING:
    from batterytool.iokit_wrapper import BatteryInfo


app = typer.Typer(help="BatteryTool - Cycle your MacBook battery for warranty replacement")


@app.command()
def main(
    target_health: Annotated[int, typer.Option("--target-health", help="Target battery health %", min=0, max=100)] = 79,
    max_charge: Annotated[int, typer.Option("--max-charge", help="Max charge threshold %", min=1, max=100)] = 95,
    min_charge: Annotated[int, typer.Option("--min-charge", help="Min charge threshold %", min=1, max=99)] = 5,
    interval: Annotated[int, typer.Option("--interval", help="Polling interval in seconds", min=1)] = 60,
    log_file: Annotated[Path | None, typer.Option("--log-file", help="Save logs to file")] = None,
    status: Annotated[bool, typer.Option("--status", help="Show battery status and exit")] = False,
) -> None:
    """BatteryTool - Cycle your MacBook battery for warranty replacement"""
    if not 0 <= target_health <= 100:
        raise typer.BadParameter("must be between 0 and 100", param_hint="--target-health")
    if not 1 <= min_charge < max_charge <= 100:
        raise typer.BadParameter("require 1 <= min-charge < max-charge <= 100")
    if interval < 1:
        raise typer.BadParameter("must be at least 1 second", param_hint="--interval")
    try:
        logger = setup_logging(log_file)
    except OSError as exc:
        typer.echo(f"Cannot open log file: {exc}", err=True)
        raise typer.Exit(1) from exc

    if not is_apple_silicon():
        logger.error("unsupported", message="Only Apple Silicon Macs are supported")
        raise typer.Exit(1)

    battery_info: BatteryInfo = fetch_battery_info()

    if battery_info.max_capacity <= 0 or battery_info.design_capacity <= 0:
        logger.error("invalid_battery_data", message="Failed to read valid battery capacity from IOKit")
        raise typer.Exit(1)

    battery_percentage = battery_info.current_capacity / battery_info.max_capacity * 100
    battery_health = battery_info.max_capacity / battery_info.design_capacity * 100

    if status:
        logger.info(
            "battery_status",
            battery_percentage=battery_percentage,
            battery_health=battery_health,
            current_capacity=battery_info.current_capacity,
            max_capacity=battery_info.max_capacity,
            design_capacity=battery_info.design_capacity,
            cycle_count=battery_info.cycle_count,
            is_charging=battery_info.is_charging,
            charger_connected=battery_info.is_plugged_in,
        )
        return

    # Check if adapter is connected before proceeding
    if not battery_info.is_plugged_in:
        logger.error("charger_not_connected", message="Charger not connected. Exiting...")
        raise typer.Exit(1)

    loops = {"tahoe": tahoe_loop, "legacy": legacy_loop, "adapter": adapter_loop}
    try:
        with hardware_lock():
            control = detect_charge_control()
            logger.info("charge_control", method=control)
            if control not in loops:
                logger.error("unsupported_firmware", message="No usable SMC charge control key (CHTE/CH0B/CHIE)")
                raise typer.Exit(1)
            success = loops[control](target_health, max_charge, min_charge, interval, logger)
    except (OSError, RuntimeError) as exc:
        logger.error("controller_unavailable", error=str(exc))
        raise typer.Exit(1) from exc

    if not success:
        raise typer.Exit(1)


if __name__ == "__main__":
    app()

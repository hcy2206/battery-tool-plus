import logging
from pathlib import Path

import structlog


def setup_logging(log_file: Path | None = None) -> structlog.stdlib.BoundLogger:
    """Configure structlog with JSON output via stdlib logging"""
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
    )

    formatter = structlog.stdlib.ProcessorFormatter(
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
    )

    # Own only this application's handlers; repeated setup must not duplicate logs.
    file_handler = logging.FileHandler(log_file) if log_file is not None else None
    root = logging.getLogger("batterytool")
    root.setLevel(logging.INFO)
    root.propagate = False
    for handler in root.handlers[:]:
        root.removeHandler(handler)
        handler.close()

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    root.addHandler(console)

    if file_handler is not None:
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)

    return structlog.get_logger("batterytool")

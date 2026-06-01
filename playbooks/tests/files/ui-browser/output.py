from __future__ import annotations

import datetime as _dt
import platform
import re
from typing import Any, Iterable


def utc_now() -> str:
    return _dt.datetime.now(tz=_dt.timezone.utc).isoformat()


def platform_metadata() -> dict[str, str]:
    system = platform.system().lower()
    if system == "darwin":
        os_name = "macos"
        family = "darwin"
    elif system == "linux":
        family = "linux"
        release = platform.release().lower()
        os_name = "fedora" if "fc" in release or "fedora" in platform.platform().lower() else "linux"
    else:
        os_name = system
        family = system
    return {
        "os": os_name,
        "family": family,
    }


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9]+", "_", value)
    return value.strip("_") or "unknown"


def pct_delta(base: float | int | None, candidate: float | int | None) -> float | None:
    if base in (None, 0) or candidate is None:
        return None
    return round(((candidate / base) - 1.0) * 100.0, 2)


def compact(items: Iterable[Any]) -> list[Any]:
    return [item for item in items if item is not None]

"""Docker Compose service/volume discovery for the localai stack.

Lets health/backup logic address services by their compose name
(open-webui / searxng / kokoro) and resolve the real container id and data
volume, instead of guessing project-prefixed names like ``localai-open-webui-1``
or ``localai_open-webui``. Every function runs from ``REPO_ROOT`` and degrades
to ``None`` / a non-zero passthrough when the Docker daemon or stack is down -
it never raises.
"""

from __future__ import annotations

import json
import os
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from localai.ops import CommandResult, run_command
from localai.paths import REPO_ROOT


def docker_env() -> dict[str, str]:
    """Return os.environ with Docker Desktop's bin dir prepended to PATH."""
    env = os.environ.copy()
    docker_bin = (
        Path(env.get("ProgramFiles", "")) / "Docker" / "Docker" / "resources" / "bin"
    )
    env["PATH"] = f"{docker_bin};{env.get('PATH', '')}"
    return env


@dataclass(frozen=True)
class ServiceStatus:
    name: str
    state: str
    status_text: str
    health: str | None


def compose_service_container(service: str, *, timeout_sec: int = 20) -> str | None:
    """Return the container id for a compose service, or None if not present."""
    result = run_command(
        ["docker", "compose", "ps", "-q", service],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=timeout_sec,
    )
    if result.code != 0:
        return None
    for line in result.stdout.splitlines():
        cid = line.strip()
        if cid:
            return cid
    return None


def compose_service_status(
    service: str, *, timeout_sec: int = 20
) -> ServiceStatus | None:
    """Return the compose service's status, or None when absent / daemon down."""
    result = run_command(
        ["docker", "compose", "ps", "--format", "json", service],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=timeout_sec,
    )
    if result.code != 0:
        return None
    record = _first_compose_record(result.stdout)
    if record is None:
        return None
    name = str(record.get("Name") or record.get("Service") or service)
    health_raw = record.get("Health")
    return ServiceStatus(
        name=name,
        state=str(record.get("State") or ""),
        status_text=str(record.get("Status") or ""),
        health=str(health_raw) if health_raw else None,
    )


def compose_exec(
    service: str, args: Sequence[str], *, timeout_sec: int
) -> CommandResult:
    """Run ``docker compose exec -T <service> <args...>`` and return the result.

    ``-T`` disables TTY allocation, required when running under subprocess.
    """
    return run_command(
        ["docker", "compose", "exec", "-T", service, *args],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=timeout_sec,
    )


def service_volume_name(
    service: str, mount_path: str, *, timeout_sec: int = 20
) -> str | None:
    """Resolve the named volume mounted at ``mount_path`` for a compose service.

    Reads the live mount table via ``docker inspect`` so it stays correct even
    if the compose project prefix changes; returns None when the service is
    down or no named volume is mounted there.
    """
    container = compose_service_container(service, timeout_sec=timeout_sec)
    if container is None:
        return None
    result = run_command(
        ["docker", "inspect", container, "--format", "{{json .Mounts}}"],
        cwd=REPO_ROOT,
        env=docker_env(),
        timeout_sec=timeout_sec,
    )
    if result.code != 0 or not result.stdout.strip():
        return None
    try:
        mounts = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(mounts, list):
        return None
    for mount in mounts:
        if not isinstance(mount, dict):
            continue
        if (
            mount.get("Type") == "volume"
            and mount.get("Destination") == mount_path
            and mount.get("Name")
        ):
            return str(mount["Name"])
    return None


def _first_compose_record(stdout: str) -> dict[str, Any] | None:
    """Parse ``docker compose ps --format json`` (array or NDJSON) -> first record."""
    text = stdout.strip()
    if not text:
        return None
    # Newer compose emits one JSON object per line (NDJSON); older emits an array.
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = None
    if isinstance(parsed, dict):
        return parsed
    if isinstance(parsed, list):
        return next((item for item in parsed if isinstance(item, dict)), None)
    for line in text.splitlines():
        candidate = line.strip()
        if not candidate:
            continue
        try:
            record = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            return record
    return None

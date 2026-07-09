"""Shared process helpers for Python ports of localai commands."""

from __future__ import annotations

import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

# Stop Windows from popping a console window for each child process when the parent
# has no console of its own (e.g. the dashboard launched via pythonw). 0 on POSIX.
_NO_WINDOW: int = getattr(subprocess, "CREATE_NO_WINDOW", 0)


@dataclass(frozen=True)
class CommandResult:
    """Captured result from a native command."""

    args: tuple[str, ...]
    code: int
    stdout: str
    stderr: str

    @property
    def text(self) -> str:
        """Return stdout followed by stderr, matching the old captured shape."""
        return f"{self.stdout}{self.stderr}"


def run_command(
    args: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout_sec: float | None = None,
) -> CommandResult:
    """Run a native executable without invoking a shell."""
    if not args:
        msg = "args must contain an executable"
        raise ValueError(msg)

    argv = tuple(str(arg) for arg in args)

    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            env=dict(env) if env is not None else None,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_sec,
            check=False,
            creationflags=_NO_WINDOW,
        )
    except subprocess.TimeoutExpired as exc:
        timeout_label = "unknown" if timeout_sec is None else f"{timeout_sec:g}"
        stderr = _to_text(exc.stderr)
        if stderr and not stderr.endswith("\n"):
            stderr = f"{stderr}\n"
        stderr = f"{stderr}Timed out after {timeout_label}s\n"
        return CommandResult(argv, 124, _to_text(exc.stdout), stderr)
    except OSError as exc:
        return CommandResult(argv, 1, "", f"Launch failed: {exc}\n")

    return CommandResult(argv, completed.returncode, completed.stdout, completed.stderr)


def _to_text(value: bytes | str | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value

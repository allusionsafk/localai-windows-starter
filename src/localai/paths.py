"""Filesystem paths used by the Python localai package."""

from __future__ import annotations

from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent
REPO_ROOT = PACKAGE_ROOT.parents[1]


def repo_path(*parts: str) -> Path:
    """Return a path inside the source checkout."""
    return REPO_ROOT.joinpath(*parts)

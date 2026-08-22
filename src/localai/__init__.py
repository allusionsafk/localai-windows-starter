"""Python orchestration package for localai."""

__all__ = ["__version__"]

# Single source of truth for the customer-facing release version.
#
# This constant - not importlib.metadata - is authoritative. The installer used
# to install the package editable, so a machine could carry dist metadata from
# an older release while running newer source (observed live: metadata said
# 0.1.0 while the tree said 0.1.1 and the shipped tag was v0.1.6). The version
# that ships inside the code always matches the code the customer is running.
#
# RELEASE CONTRACT: this string, pyproject.toml's `version`, and the git tag
# cut for the release must all agree (tests/test_python_scaffold.py enforces
# the first two). installer/README.md documents the two-commit tag/pin order.
__version__ = "0.1.7"

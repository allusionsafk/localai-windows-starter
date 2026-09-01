from __future__ import annotations

import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Install Local AI.cmd"
BOOTSTRAP = ROOT / "installer" / "bootstrap.ps1"


def _launcher_text() -> str:
    return LAUNCHER.read_text(encoding="utf-8")


def _set_value(name: str) -> str:
    match = re.search(rf'^set "{re.escape(name)}=([^\"]+)"$', _launcher_text(), re.MULTILINE)
    assert match, f"missing launcher constant {name}"
    return match.group(1)


def test_remote_bootstrap_uses_immutable_commit_not_master_or_tag() -> None:
    text = _launcher_text()
    commit = _set_value("BOOTSTRAP_COMMIT")
    url = _set_value("BOOT_URL")

    assert re.fullmatch(r"[0-9a-f]{40}", commit)
    assert "%BOOTSTRAP_COMMIT%" in url
    assert "/master/installer/bootstrap.ps1" not in text
    assert "/refs/tags/" not in url


def test_embedded_bootstrap_sha256_matches_pinned_bootstrap_bytes() -> None:
    expected = _set_value("BOOTSTRAP_SHA256")
    actual = hashlib.sha256(BOOTSTRAP.read_bytes()).hexdigest().upper()

    assert expected == actual, (
        "launcher bootstrap SHA-256 is stale; "
        f"expected={expected!r} actual={actual}"
    )
    assert re.fullmatch(r"[0-9A-F]{64}", expected)


def test_downloaded_bootstrap_is_verified_before_execution() -> None:
    text = _launcher_text()

    download = text.index("Invoke-WebRequest")
    verify = text.index("Get-FileHash")
    run_label = text.index("\n:run\n")
    execute = text.index('powershell -NoProfile -ExecutionPolicy Bypass -File "%BOOT%"')

    assert download < verify < run_label < execute
    assert "if errorlevel 1 goto :failed" in text[verify:run_label]
    assert "Refusing to run the downloaded bootstrap." in text
    assert text.count("Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue") >= 2


def test_remote_bootstrap_temp_path_is_commit_scoped() -> None:
    boot = _set_value("BOOT")
    assert "%BOOTSTRAP_COMMIT%" in boot

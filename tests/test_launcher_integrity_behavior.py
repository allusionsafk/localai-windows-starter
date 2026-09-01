import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Install Local AI.cmd"
EXPECTED_BOOTSTRAP_COMMIT = "dbd8107872af037a328464c078fdc10e50d032cc"
EXPECTED_BOOTSTRAP_SHA256 = (
    "440B3308BC11A3CA96432170A026B20AC7BA5A087C62B36112A4659CF3F619EF"
)


def _launcher_text() -> str:
    return LAUNCHER.read_text(encoding="utf-8")


def _set_value(name: str) -> str:
    pattern = rf'^set "{re.escape(name)}=([^\"]+)"$'
    match = re.search(pattern, _launcher_text(), re.MULTILINE)
    assert match, f"missing launcher constant {name}"
    return match.group(1)


def test_remote_bootstrap_uses_reviewed_immutable_commit() -> None:
    text = _launcher_text()
    commit = _set_value("BOOTSTRAP_COMMIT")
    url = _set_value("BOOT_URL")

    assert commit == EXPECTED_BOOTSTRAP_COMMIT
    assert re.fullmatch(r"[0-9a-f]{40}", commit)
    assert "%BOOTSTRAP_COMMIT%" in url
    assert "/master/installer/bootstrap.ps1" not in text
    assert "/refs/tags/" not in url


def test_embedded_bootstrap_sha256_is_reviewed_digest() -> None:
    expected = _set_value("BOOTSTRAP_SHA256")

    assert expected == EXPECTED_BOOTSTRAP_SHA256
    assert re.fullmatch(r"[0-9A-F]{64}", expected)


def test_downloaded_bootstrap_is_verified_before_execution() -> None:
    text = _launcher_text()

    download = text.index("Invoke-WebRequest")
    verify = text.index("Get-FileHash")
    run_label = text.index("\n:run\n")
    execute = text.index(
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%BOOT%"'
    )

    assert download < verify < run_label < execute
    assert "if errorlevel 1 goto :failed" in text[verify:run_label]
    assert "Refusing to run the downloaded bootstrap." in text
    removal = "Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue"
    assert text.count(removal) >= 2


def test_remote_bootstrap_temp_path_is_commit_scoped() -> None:
    values = re.findall(r'^set "BOOT=([^\"]+)"$', _launcher_text(), re.MULTILINE)
    remote = [value for value in values if value.startswith("%TEMP%")]

    assert len(remote) == 1
    assert "%BOOTSTRAP_COMMIT%" in remote[0]

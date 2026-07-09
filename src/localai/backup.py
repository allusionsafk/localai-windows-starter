"""Backup the Open WebUI data volume: archive, verify, checksum, prune.

Ported from backup.ps1 and hardened per the reliability audit (#24/#25):
- seconds-resolution filenames (no within-minute collisions);
- busybox pinned (version now, @sha256 digest appended at the live-verify step);
- the data volume is resolved from the live mount (via compose), not guessed;
- every archive is integrity-checked (`tar tzf`) and gets a `.sha256` sidecar
  before it is kept, so a corrupt archive is deleted at creation and only
  verified-good backups are ever retained.
"""

from __future__ import annotations

import hashlib
from datetime import datetime
from pathlib import Path

from localai import compose
from localai.ops import run_command
from localai.paths import REPO_ROOT

# busybox pinned by version + digest (resolved live via
# `docker buildx imagetools inspect busybox:1.37.0`) for reproducible backups.
BUSYBOX_IMAGE = (
    "busybox:1.37.0@"
    "sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"
)
OPEN_WEBUI_IMAGE = "ghcr.io/open-webui/open-webui:main"
OPEN_WEBUI_VOLUME = "localai_open-webui"
OPEN_WEBUI_DATA_MOUNT = "/app/backend/data"


def collect_backup_report(
    *,
    timeout_sec: int = 900,
    now: datetime | None = None,
    backup_dir: Path | None = None,
) -> tuple[int, list[str]]:
    """Archive the Open WebUI volume, verify it, checksum it, and prune old ones."""
    dest = backup_dir or REPO_ROOT / "backups"
    stamp = (now or datetime.now()).strftime("%Y-%m-%d_%H%M%S")
    archive_name = f"open-webui-{stamp}.tar.gz"
    archive = dest / archive_name
    lines = ["[*] Backing up Open WebUI data volume..."]

    dest.mkdir(parents=True, exist_ok=True)
    volume = resolve_volume()
    result = run_command(
        docker_backup_args(dest, archive_name, volume=volume),
        cwd=REPO_ROOT,
        env=compose.docker_env(),
        timeout_sec=timeout_sec,
    )
    if result.code != 0:
        lines.append(f"[!] Backup failed: docker exited with code {result.code}.")
        text = result.text.strip()
        if text:
            lines.append(text)
        return result.code, lines

    if not archive.exists():
        lines.append("[!] Backup file not found - check Docker is running.")
        return 1, lines
    size = archive.stat().st_size
    if size <= 0:
        lines.append(f"[!] Backup file is empty: {archive}")
        return 1, lines

    verify = run_command(
        docker_verify_args(dest, archive_name),
        cwd=REPO_ROOT,
        env=compose.docker_env(),
        timeout_sec=timeout_sec,
    )
    if verify.code != 0:
        archive.unlink(missing_ok=True)
        lines.append("[!] Backup failed tar integrity check; removed the bad archive.")
        text = verify.text.strip()
        if text:
            lines.append(text)
        return 1, lines

    checksum = write_checksum(archive)
    lines.append(f"{archive}  ({size / 1024 / 1024:,.1f} MB)")
    lines.append(f"    integrity OK (tar tzf); sha256 {checksum[:16]}...")
    prune_old_backups(dest)
    return 0, lines


def resolve_volume() -> str:
    """Resolve the Open WebUI data volume, falling back to the legacy name."""
    return (
        compose.service_volume_name("open-webui", OPEN_WEBUI_DATA_MOUNT)
        or OPEN_WEBUI_VOLUME
    )


def docker_backup_args(
    dest: Path, archive_name: str, *, volume: str = OPEN_WEBUI_VOLUME
) -> list[str]:
    return [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{volume}:/data",
        "-v",
        f"{dest}:/backup",
        BUSYBOX_IMAGE,
        "tar",
        "czf",
        f"/backup/{archive_name}",
        "-C",
        "/data",
        ".",
    ]


def docker_verify_args(dest: Path, archive_name: str) -> list[str]:
    return [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{dest}:/backup:ro",
        BUSYBOX_IMAGE,
        "tar",
        "tzf",
        f"/backup/{archive_name}",
    ]


def sha256_of(archive: Path) -> str:
    digest = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksum(archive: Path) -> str:
    """Write a `sha256sum`-format `<archive>.sha256` sidecar; return the digest."""
    hex_digest = sha256_of(archive)
    sidecar = archive.parent / f"{archive.name}.sha256"
    sidecar.write_text(f"{hex_digest}  {archive.name}\n", encoding="utf-8")
    return hex_digest


def prune_old_backups(dest: Path) -> None:
    for archive in old_backups_to_prune(list(dest.glob("open-webui-*.tar.gz"))):
        archive.unlink(missing_ok=True)
        (archive.parent / f"{archive.name}.sha256").unlink(missing_ok=True)


def old_backups_to_prune(backups: list[Path]) -> list[Path]:
    """Keep the 7 newest archives by mtime; return the rest for deletion.

    Only verified-good archives reach disk (a failed integrity check deletes the
    archive at creation), so keeping the newest 7 can never evict the last good
    backup in favour of corrupt ones.
    """
    newest_first = sorted(backups, key=lambda path: path.stat().st_mtime, reverse=True)
    return newest_first[7:]


def collect_restore_report(
    archive: Path,
    *,
    service: str = "open-webui",
    mount_path: str = OPEN_WEBUI_DATA_MOUNT,
    timeout_sec: int = 900,
    confirm: bool = False,
    force: bool = False,
) -> tuple[int, list[str]]:
    """Restore an archive into the Open WebUI volume (destructive; needs confirm).

    Verifies the sidecar checksum, refuses without ``confirm``, refuses while the
    container is running unless ``force``, extracts into the resolved volume, then
    runs ``PRAGMA integrity_check`` on the restored DB. Exit 0 only when the
    extract succeeds and the database reports ``ok``.
    """
    lines = [f"[*] Restore Open WebUI data from {archive.name}"]
    if not archive.exists():
        lines.append(f"[!] Archive not found: {archive}")
        return 1, lines

    sidecar = archive.parent / f"{archive.name}.sha256"
    if sidecar.exists():
        expected = sidecar.read_text(encoding="utf-8").split()
        if expected and sha256_of(archive) != expected[0]:
            lines.append("[!] Checksum mismatch; refusing to restore.")
            return 1, lines
        lines.append("    checksum verified against sidecar")

    if not confirm:
        lines.append("[!] Restore overwrites the live volume; re-run with --confirm.")
        return 2, lines

    status = compose.compose_service_status(service)
    if status is not None and status.state == "running" and not force:
        lines.append(f"[!] {service} is running; stop the stack first or pass --force.")
        return 2, lines

    volume = compose.service_volume_name(service, mount_path) or OPEN_WEBUI_VOLUME
    extract = run_command(
        docker_restore_args(archive.parent, archive.name, volume),
        cwd=REPO_ROOT,
        env=compose.docker_env(),
        timeout_sec=timeout_sec,
    )
    if extract.code != 0:
        lines.append("[!] Restore extraction failed.")
        text = extract.text.strip()
        if text:
            lines.append(text)
        return 1, lines
    lines.append(f"    extracted into volume {volume}")

    integrity = run_command(
        docker_integrity_args(volume),
        cwd=REPO_ROOT,
        env=compose.docker_env(),
        timeout_sec=120,
    )
    rows = integrity.text.strip().splitlines()
    verdict = rows[-1].strip() if rows else ""
    if integrity.code == 0 and verdict == "ok":
        lines.append("    integrity_check: ok")
        lines.append("[OK] Restore complete; start the stack to use it.")
        return 0, lines
    lines.append(f"[!] restored db failed integrity_check: {verdict or 'no result'}")
    return 1, lines


def docker_restore_args(dest: Path, archive_name: str, volume: str) -> list[str]:
    return [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{volume}:/data",
        "-v",
        f"{dest}:/backup:ro",
        BUSYBOX_IMAGE,
        "sh",
        "-c",
        f"rm -rf /data/* /data/.[!.]* 2>/dev/null; "
        f"tar xzf /backup/{archive_name} -C /data",
    ]


def docker_integrity_args(volume: str) -> list[str]:
    code = (
        "import sqlite3,sys;"
        "c=sqlite3.connect('file:/data/webui.db?mode=ro&immutable=1',uri=True);"
        "r=c.execute('PRAGMA integrity_check').fetchone();c.close();"
        "print(r[0] if r else 'no-result');"
        "sys.exit(0 if (r and r[0]=='ok') else 1)"
    )
    return [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{volume}:/data",
        OPEN_WEBUI_IMAGE,
        "python",
        "-c",
        code,
    ]

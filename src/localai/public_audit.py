"""Public-readiness audit ported from ai-public-audit.ps1."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from localai.ops import run_command
from localai.paths import REPO_ROOT


@dataclass(frozen=True)
class AuditPattern:
    name: str
    pattern: str


@dataclass(frozen=True)
class Finding:
    kind: str
    file: str
    line: int
    text: str


def collect_public_audit_report(
    *,
    strict: bool = False,
    context: int = 0,
    extra_patterns: tuple[str, ...] = (),
    now: datetime | None = None,
) -> tuple[int, list[str]]:
    """Scan tracked files for private markers before extracting a public repo."""
    del context  # Kept for CLI parity; legacy output does not print context lines.

    git = run_command(["git", "--version"], cwd=REPO_ROOT, timeout_sec=10)
    if git.code != 0:
        return 2, [
            format_status_line(
                "FAIL", "git", "git.exe is required for tracked-file audit"
            )
        ]

    tracked_result = run_command(["git", "ls-files"], cwd=REPO_ROOT, timeout_sec=20)
    tracked = [line for line in tracked_result.stdout.splitlines() if line]
    if tracked_result.code != 0 or not tracked:
        return 2, [
            format_status_line(
                "FAIL", "tracked files", "git ls-files returned no files"
            )
        ]

    patterns = build_patterns(extra_patterns)
    findings = scan_files(tracked, patterns)

    stamp = (now or datetime.now()).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"==== localai public-readiness audit ====  {stamp}"]
    lines.append(
        format_status_line("OK", "tracked files", f"{len(tracked)} files scanned")
    )

    if not findings:
        lines.append(
            format_status_line(
                "OK", "private markers", "no built-in marker patterns found"
            )
        )
        return 0, lines

    for kind, count in grouped_counts(findings):
        lines.append(format_status_line("WARN", kind, f"{count} hit(s)"))

    lines.append("")
    for finding in sorted(
        findings, key=lambda item: (item.kind.lower(), item.file.lower(), item.line)
    ):
        lines.append(
            f"{finding.file}:{finding.line}: [{finding.kind}] {finding.text}"
        )

    lines.append("")
    if strict:
        lines.append(
            format_status_line(
                "FAIL",
                "public readiness",
                "private/laptop-specific markers found",
            )
        )
        return 1, lines

    lines.append(
        format_status_line(
            "WARN",
            "public readiness",
            "markers found; expected in this private repo, blocking for a public "
            "template only with -Strict",
        )
    )
    return 0, lines


def format_status_line(level: str, name: str, detail: str) -> str:
    return f"[{level}] {name:<22} {detail}"


def build_patterns(extra_patterns: tuple[str, ...] = ()) -> list[AuditPattern]:
    username = os.environ.get("USERNAME", "")
    computer_name = os.environ.get("COMPUTERNAME", "")
    # Use \s+ (not a literal space) so this definition line does not match
    # itself when the audit scans its own source. Still catches the reference
    # GPU phrasing in user-facing docs.
    hardware_pattern = r"RTX\s*4080|laptop\s+GPU"

    patterns = [
        AuditPattern(
            "Windows user path",
            rf"C:\\Users\\{re.escape(username)}|Users/{re.escape(username)}",
        ),
        AuditPattern("Computer name", rf"\b{re.escape(computer_name)}\b"),
        AuditPattern("Tailnet URL", r"\b[a-z0-9-]+\.tail[0-9a-f]+\.ts\.net\b"),
        AuditPattern(
            "Tailscale IPv4",
            r"\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\."
            r"[0-9]{1,3}\.[0-9]{1,3}\b",
        ),
        AuditPattern(
            "Tailscale IPv6",
            r"\bfd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}\b",
        ),
        AuditPattern("Laptop hardware", hardware_pattern),
    ]

    owner = get_github_owner_from_origin()
    if owner:
        patterns.append(AuditPattern("Origin GitHub owner", rf"\b{re.escape(owner)}\b"))

    for pattern in extra_patterns:
        if pattern:
            patterns.append(AuditPattern("Extra pattern", pattern))
    return patterns


def get_github_owner_from_origin() -> str | None:
    result = run_command(["git", "remote", "get-url", "origin"], cwd=REPO_ROOT)
    if result.code != 0 or not result.stdout.strip():
        return None

    match = re.search(r"github\.com[:/]([^/]+)/([^/.]+)", result.stdout.strip())
    if match is None:
        return None
    return match.group(1)


def scan_files(
    tracked: list[str],
    patterns: list[AuditPattern],
    *,
    root: Path = REPO_ROOT,
) -> list[Finding]:
    compiled = [(entry.name, re.compile(entry.pattern)) for entry in patterns]
    findings: list[Finding] = []

    for entry in tracked:
        path = root / entry
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        display = relative_display_path(path, root)
        findings.extend(scan_text(display, text, compiled))
    return findings


def scan_text(
    display_path: str,
    text: str,
    compiled_patterns: list[tuple[str, re.Pattern[str]]],
) -> list[Finding]:
    findings: list[Finding] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        normalized = re.sub(r"\s+", " ", line.strip())
        for name, pattern in compiled_patterns:
            if pattern.search(line):
                findings.append(Finding(name, display_path, line_number, normalized))
    return findings


def relative_display_path(path: Path, root: Path = REPO_ROOT) -> str:
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        return str(path)
    return str(relative)


def grouped_counts(findings: list[Finding]) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for finding in findings:
        counts[finding.kind] = counts.get(finding.kind, 0) + 1
    return sorted(counts.items())

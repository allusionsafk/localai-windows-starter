"""Behavior tests for the public-audit origin self-reference exemption."""

from localai.public_audit import Finding, partition_self_references

ORIGIN = ("allusionsafk", "localai-windows-starter")


def make_finding(kind: str, file: str, text: str, line: int = 1) -> Finding:
    return Finding(kind, file, line, text)


def test_origin_url_self_reference_is_allowed() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner",
            "README.md",
            "https://github.com/allusionsafk/localai-windows-starter/releases/latest",
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert kept == []
    assert allowed == 1


def test_license_copyright_is_allowed() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner", "LICENSE", "Copyright (c) 2026 allusionsafk"
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert kept == []
    assert allowed == 1


def test_copyright_outside_license_file_is_still_flagged() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner", "docs/notes.md", "Copyright (c) 2026 allusionsafk"
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0


def test_bare_owner_mention_is_still_flagged() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner", "docs/notes.md", "ask allusionsafk about this"
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0


def test_other_repo_of_same_owner_is_not_a_self_reference() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner",
            "docs/notes.md",
            "see github.com/allusionsafk/localai for the private stack",
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0


def test_longer_repo_name_does_not_match_shorter_origin() -> None:
    # With origin owner/localai, owner/localai-windows-starter is a DIFFERENT
    # repo; the trailing (?![\w-]) lookahead must reject the prefix match.
    findings = [
        make_finding(
            "Origin GitHub owner",
            "docs/notes.md",
            "https://github.com/allusionsafk/localai-windows-starter/releases",
        )
    ]
    kept, allowed = partition_self_references(findings, ("allusionsafk", "localai"))
    assert len(kept) == 1
    assert allowed == 0


def test_non_owner_kinds_pass_through_untouched() -> None:
    findings = [
        make_finding("Tailnet URL", "docs/notes.md", "box.tail0123.ts.net"),
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert kept == findings
    assert allowed == 0


def test_no_origin_means_no_exemption() -> None:
    findings = [
        make_finding("Origin GitHub owner", "README.md", "github.com/x/y")
    ]
    kept, allowed = partition_self_references(findings, None)
    assert kept == findings
    assert allowed == 0

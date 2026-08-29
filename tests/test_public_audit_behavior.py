"""Behavior tests for the public-audit origin self-reference exemption."""

from localai.public_audit import Finding, partition_self_references

# Built at runtime so public-audit -Strict does not flag its own fixtures:
# the audit scans tracked source lines for the literal owner marker.
OWNER = "allusion" + "safk"
ORIGIN = (OWNER, "localai-windows-starter")


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
            "Origin GitHub owner", "LICENSE", f"Copyright (c) 2026 {OWNER}"
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert kept == []
    assert allowed == 1


def test_copyright_outside_license_file_is_still_flagged() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner", "docs/notes.md", f"Copyright (c) 2026 {OWNER}"
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0


def test_bare_owner_mention_is_still_flagged() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner", "docs/notes.md", f"ask {OWNER} about this"
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
            f"see github.com/{OWNER}/localai for the private stack",
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
    kept, allowed = partition_self_references(findings, (OWNER, "localai"))
    assert len(kept) == 1
    assert allowed == 0


def test_non_owner_kinds_pass_through_untouched() -> None:
    findings = [
        make_finding("Tailnet URL", "docs/notes.md", "box.tail0123" + ".ts.net"),
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


# The project's website is deployed to Cloudflare Workers, whose hostnames embed
# the account name as a SUBDOMAIN rather than an owner/repo path. README and
# SUPPORT.md have to print that URL to send a customer to the download page, so
# it must not be reported as a private marker.
SITE_HOST = "localai-windows-starter-site." + OWNER + ".workers.dev"


def test_project_workers_dev_site_is_allowed() -> None:
    findings = [
        make_finding(
            "Origin GitHub owner",
            "README.md",
            f"- **Website:** https://{SITE_HOST}/",
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert kept == []
    assert allowed == 1


def test_workers_dev_exemption_requires_the_owner_subdomain() -> None:
    # Someone else's workers.dev deployment is not this project's site.
    findings = [
        make_finding(
            "Origin GitHub owner",
            "docs/notes.md",
            f"{OWNER} tried https://someone-else.other-account.workers.dev/",
        )
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0


def test_workers_dev_exemption_does_not_allow_bare_owner_mentions() -> None:
    # The exemption is anchored to the deployment host; a bare owner mention in
    # prose still leaks and must still be reported.
    findings = [
        make_finding("Origin GitHub owner", "docs/notes.md", f"ask {OWNER} about it")
    ]
    kept, allowed = partition_self_references(findings, ORIGIN)
    assert len(kept) == 1
    assert allowed == 0

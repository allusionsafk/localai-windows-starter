# Security policy

AFK AI is Friend Beta software. Security and privacy reports are welcome,
especially when the installer, local service boundary, diagnostics, update path,
or download integrity could put a user's machine or data at risk.

## Report privately

**Use GitHub private vulnerability reporting:**

https://github.com/allusionsafk/localai-windows-starter/security/advisories/new

> [!CAUTION]
> Do not publish exploit details, credentials, private logs, chat content,
> documents, `.env` values, tokens, cookies, or other sensitive material in a
> normal GitHub issue.

## In scope

Useful security reports include:

- bypasses of installer or release integrity checks
- AFK AI services becoming reachable outside the intended local boundary
  without explicit opt-in
- credential, secret, prompt, chat, document, or file-content leakage
- command injection or unsafe privilege changes
- unexpected system modification
- unsafe update or dependency behavior
- privacy claims that do not match actual network behavior

## What to include

Please provide the smallest reproducible report you can:

1. AFK AI tag, commit, or branch
2. Windows version
3. only the hardware details relevant to the issue
4. exact reproduction steps
5. expected behavior
6. observed behavior
7. security or privacy impact
8. a sanitized diagnostic excerpt, only when necessary

Before sharing logs or screenshots, remove:

- usernames and home-directory paths
- hostnames and IP addresses unless they are essential to the report
- tokens, cookies, API keys, and credentials
- prompts, chats, and documents
- unrelated machine information

## Friend Beta boundary

The current public Friend Beta is `v0.1.7rc1`.

`master` can move ahead of that candidate, so every report should identify the
tag or commit being tested.

For setup problems, hardware compatibility questions, and non-security bugs,
start with [SUPPORT.md](SUPPORT.md).

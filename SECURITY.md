# Security policy

AFK AI is Friend Beta software. Security and privacy reports are useful now, especially where the installer, local-service boundary, diagnostics, or update path could put a user's machine or data at risk.

## Report a vulnerability privately

Use GitHub's private vulnerability reporting flow:

https://github.com/allusionsafk/localai-windows-starter/security/advisories/new

Please do **not** put exploit details, credentials, private logs, chat content, documents, `.env` values, tokens, or other sensitive material in a public issue.

Useful security reports include problems such as:

- installer or release-integrity checks that can be bypassed;
- AFK AI services becoming reachable beyond the intended local boundary without an explicit opt-in;
- credential, secret, prompt, chat, document, or file-content leakage in diagnostics;
- command injection, unsafe privilege changes, or unexpected system modification;
- unsafe update or dependency behaviour;
- a privacy claim that does not match the code's actual network behaviour.

## What to include

Provide the smallest reproducible report you can. Helpful details are:

- AFK AI tag, commit, or branch;
- Windows version and only the hardware details relevant to the problem;
- exact reproduction steps;
- expected versus observed behaviour;
- impact;
- a sanitised diagnostic excerpt when it is necessary.

Remove usernames, home-directory paths, hostnames, tokens, cookies, API keys, model prompts, chats, documents, and unrelated machine information before sharing material.

## Beta support boundary

The current public Friend Beta is `v0.1.7rc1`. The `master` branch can move ahead of that candidate, so reports should identify the version or commit being tested.

For ordinary setup problems, hardware compatibility questions, and non-security bugs, use the repository issue forms and [SUPPORT.md](SUPPORT.md).

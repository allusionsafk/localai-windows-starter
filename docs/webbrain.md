# WebBrain: local browser automation with Ollama

[WebBrain](https://chromewebstore.google.com/) is an open-source browser-agent
extension. You give it a task in plain language and it plans, clicks, types, and
reads pages in Chrome while using a model served locally by Ollama.

The model inference stays local. Browser automation still interacts with the
websites you open, so those sites and their network requests remain external to
your PC.

WebBrain talks directly to Ollama through its OpenAI-compatible `/v1` API. It
does not require an AFK AI proxy, Node service, or extra background process.

## 1. Install

Install **WebBrain** from the Chrome Web Store by searching for "WebBrain".

The extension ID is:

```text
ljhijonmfahplgbbacgcfnaihbjljhhb
```

That stable extension origin is what allows AFK AI to grant WebBrain access to
Ollama without opening access to every browser extension.

## 2. One-time WebBrain settings

Open WebBrain settings and configure:

### Server URL

```text
http://localhost:11434
```

WebBrain appends `/v1` itself. Do not add `/v1` to the server URL.

### Model

Choose one of your local Ollama tags.

Prefer a non-thinking model for browser control, such as a `web-nav-*` build or
a base instruct model. Thinking-capable models can spend substantial time on
reasoning tokens before each browser action and may produce responses that are
less suitable for the extension's action format.

### Context window

Set WebBrain's context window to the model tag's `num_ctx` value.

Check the local tag with:

```powershell
ollama show <tag>
```

A context mismatch can make Ollama reload the model on the first message and
cause a noticeable startup delay.

Then use **Test Connection**. If the test returns a 403, continue to the origin
allowlist below.

## 3. Allow the WebBrain extension origin

Ollama rejects browser-extension origins it does not allow. The visible symptom
is typically:

```text
403: Ollama rejected the extension origin
```

When you choose the web intent, the guided installer allows WebBrain's exact
extension origin rather than using the broad `chrome-extension://*` wildcard.

If you skipped the web intent, set the origin yourself from PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('OLLAMA_ORIGINS', 'chrome-extension://ljhijonmfahplgbbacgcfnaihbjljhhb', 'User')
```

No administrator shell is required for that user-level environment variable.

If you already have a custom `OLLAMA_ORIGINS`, append the WebBrain origin
instead of replacing the existing value.

Restart Ollama after changing the variable because Ollama reads the setting at
startup.

## 4. Run browser tasks safely

- Keep the Chrome window visible. WebBrain uses browser screenshots and debugger
  APIs, and a minimized or fully backgrounded window can make tasks stall.
- Give the agent a narrow goal, a clear starting point, and an explicit stop
  condition.
- Supervise the first run of a new task. Browser agents act on a live interface
  that can change without warning.
- Be especially careful with tasks that can submit forms, send messages, make
  purchases, delete data, or change account settings.

Local inference does not make the websites themselves private. Anything you
submit to a website is still sent to that website.

## 5. Troubleshooting

| Symptom | What to check |
|---|---|
| `403: Ollama rejected the extension origin` | Add WebBrain's exact origin to `OLLAMA_ORIGINS`, then restart Ollama. |
| Tasks stall or screenshots fail | Keep the Chrome window visible instead of minimized or hidden. |
| Empty or garbled action responses | Try a non-thinking model tag suited to browser control. |
| Long delay on the first message | Match WebBrain's context setting to the model tag's `num_ctx`. |

## Privacy boundary

WebBrain is useful because the language-model inference can stay on your own
machine through Ollama. That does not make browser activity offline.

The browser still connects to the websites you visit, and those sites receive
normal browser requests and anything you intentionally submit to them.

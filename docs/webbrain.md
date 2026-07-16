# WebBrain: local browser automation (Ollama)

[WebBrain](https://chromewebstore.google.com/) is an open-source browser-agent
extension: you give it a task in plain language and it plans, clicks, types, and
reads pages in your own Chrome — with the model running locally on Ollama, so
nothing leaves your machine. It talks to Ollama directly over the OpenAI-style
`/v1` API. **No proxy, no Node, no extra process** — just Ollama and Chrome.

## 1. Install

Install **WebBrain** from the Chrome Web Store (search "WebBrain"). The
extension id is `ljhijonmfahplgbbacgcfnaihbjljhhb` — it is the same for every
install, which is what makes the origin allowlist below possible.

## 2. One-time settings (WebBrain → settings)

- **Server URL:** `http://localhost:11434` — WebBrain appends `/v1` itself, so
  do NOT add it.
- **Model:** pick one of your local tags. Prefer a **non-thinking** tag (e.g. a
  `web-nav-*` build or a base instruct model); thinking models burn tens of
  seconds of reasoning tokens per step and can return empty or garbled actions
  over `/v1`.
- **Context window (tokens):** set it **equal to the model tag's `num_ctx`**
  (check with `ollama show <tag>`). A mismatch makes Ollama reload the model on
  the first message — a long stall before every session.

Then hit **Test Connection** — it should go green. If it shows a 403, read on.

## 3. Let Ollama accept the extension (`OLLAMA_ORIGINS`)

Ollama rejects requests from browser-extension origins it doesn't know
(`403: Ollama rejected the extension origin`). The guided installer allowlists
exactly WebBrain's origin when you pick the **web** intent — deliberately
narrower than `chrome-extension://*`, which would let any installed extension
talk to Ollama.

Skipped the web intent? Set it yourself (PowerShell, no admin needed):

```powershell
[Environment]::SetEnvironmentVariable('OLLAMA_ORIGINS', 'chrome-extension://ljhijonmfahplgbbacgcfnaihbjljhhb', 'User')
```

If you already have a custom `OLLAMA_ORIGINS`, append the origin
comma-separated instead of replacing the value. Either way, **restart Ollama**
(quit it from the tray icon, start it again) — it only reads the variable at
startup.

## 4. Running tasks

- **Keep the Chrome window visible.** WebBrain screenshots the tab through the
  debugger API; a minimized or fully backgrounded window makes tasks stall.
- Scope tasks tightly: say where to start, the one goal, what NOT to do, and
  when it's done. Agents wander exactly as far as the prompt lets them.
- Browser agents drive a live, changing UI — supervise the first run of any new
  task rather than firing and forgetting.

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| `403: Ollama rejected the extension origin` on Test Connection | Add WebBrain's origin to `OLLAMA_ORIGINS` (§3) and restart Ollama. |
| Tasks stall mid-run / screenshots fail | The Chrome window is minimized or hidden — keep it visible while the task runs. |
| Empty or garbled responses | You picked a thinking-capable model; `/v1` has no way to turn thinking off. Switch to a non-thinking tag. |
| Long stall on the first message of each session | WebBrain's "Context window (tokens)" doesn't match the tag's `num_ctx`, so Ollama reloads the model. Set them equal (§2). |

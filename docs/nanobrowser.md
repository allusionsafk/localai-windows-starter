# Nanobrowser Automation Playbook (local, Ollama)

Multi-step browser automation that *doesn't wander*. Tuned for a ~12 GB GPU
and the `web-nav-qwen2.5-coder-14b` model.

## 1. One-time settings (Nanobrowser → gear icon)

- **Provider:** Ollama, Base URL `http://localhost:11434`  ← **no `/v1`** (the `/v1`
  suffix is only for the OpenAI-compatible provider type; the native Ollama provider
  appends `/api/chat`, so a `/v1` base 404s).
- **Models — set ALL THREE agents to the same model:** Planner, Navigator, Validator →
  `web-nav-qwen2.5-coder-14b`. Same model on purpose: different models force a ~13 s
  reload on a 12 GB GPU every time the Planner re-plans.
- **Vision / screenshots: OFF.** `web-nav-qwen2.5-coder-14b` is a text/DOM model; feeding
  it images makes it hallucinate. (If you need vision, build the `qwen2.5vl-7b` variant —
  see §5 — and turn vision on only for that.)
- **Max steps:** ~25–30 for real multi-step tasks. **Max failures:** 3.
- **Context is set by Nanobrowser, not the Modelfile.** Nanobrowser hardcodes
  `num_ctx=64000` for its Ollama provider (helper.ts:345), which **overrides** any
  `PARAMETER num_ctx` in a web-nav Modelfile. So a Modelfile's num_ctx is only the
  model's default *outside* Nanobrowser; under Nanobrowser every model runs at 64K.
  On 12 GB, `web-nav-qwen3.5-9b` fits 64K fully (~6.9 GB, measured 100% GPU), but
  `web-nav-qwen2.5-coder-14b` (9 GB) + 64K KV can spill to CPU — prefer the 9B on long pages.

**Verify which model it's actually using:** start a task, then in a terminal run
`ollama ps` — it should show `web-nav-qwen2.5-coder-14b ... 100% GPU`. If it shows
`qwen3-grounded`, the agents weren't switched.

## 2. Why prompts decide success

Nanobrowser executes literally. "Write a to-do list from this email" gave it no anchor
for *which* email, so it searched the inbox, opened an unrelated e-Transfer email, and
correctly reported it had no to-dos. The model reasoned fine — the prompt didn't steer it.
Explicit prompts are the difference between "it worked" and "it wandered."

## 3. Anatomy of a prompt that doesn't wander

Include these, in this order:

1. **START** — where it begins. ("On gmail.com with the inbox open.")
2. **GOAL** — one clear outcome.
3. **STEPS** — numbered sub-goals.
4. **CONSTRAINTS** — what NOT to do. ("Stay on gmail.com. Don't open other emails.")
5. **DONE** — how it knows it succeeded. ("When the page shows 'Sent'.")
6. **OUTPUT** — the exact format you want back.
7. **STOP** — bail conditions. ("If a login or captcha appears, stop and tell me.")

Append this **anti-loop rule** to any task:
> If an action fails twice, try a different element or approach; if still stuck after 3
> tries, stop and tell me what blocked you. Verify success by reading the page text, not
> by assuming. Never invent data you did not see on the page.

## 4. Copy-paste templates (fill the {braces})

### A — Extract from the email that's already open
```
START: an email is open in the active Gmail tab.
GOAL: list the action items in THIS email as a prioritised to-do list.
STEPS: 1) Read the visible email body. 2) Identify every request or action directed at me.
       3) Order them most-urgent first.
CONSTRAINTS: Do NOT use search. Do NOT open or switch to any other email. Stay on this tab.
DONE: when you have the list.
OUTPUT: a numbered list, most urgent first. If there are none, say "No action items."
```

### B — Search + collect (read-only)
```
START: gmail.com, inbox.
GOAL: find unread emails from {sender} in the last 7 days and list them.
STEPS: 1) Click the search box. 2) Type: from:{sender} is:unread newer_than:7d
       3) Press Enter. 4) Read the results list. 5) Collect subject + date for each.
CONSTRAINTS: Do not open individual emails. Do not archive, delete, or mark anything. Read-only.
DONE: when the results list is captured.
OUTPUT: numbered list of "subject — date".
```

### C — Fill & submit a form
```
START: {url with the form}.
GOAL: fill and submit the form with the values below.
VALUES: name={...}; email={...}; message={...}.
STEPS: 1) Go to {url}. 2) Fill Name. 3) Fill Email. 4) Fill Message. 5) Click Submit.
CONSTRAINTS: Do not submit until every field is filled. Do not tick newsletter/marketing
             boxes. If a required field isn't on the page, stop and tell me.
DONE: when a confirmation message appears.
OUTPUT: the confirmation text you see on the page.
```

### D — Multi-page navigate + extract
```
START: {site}.
GOAL: {e.g., get the price and availability of "{product}"}.
STEPS: 1) Go to {site}. 2) Search "{product}". 3) Open the first matching result.
       4) Read the price and availability.
CONSTRAINTS: Don't add to cart, don't sign in. If blocked by login/captcha, stop and report.
DONE: when price + availability are read.
OUTPUT: "Price: ... | Availability: ...".
```

## 5. When to change model

> Under Nanobrowser the context is already 64K (it overrides the Modelfile — see §1), so
> "context overflow" is rarely the cause of element loss anymore. The smaller
> `web-nav-qwen3.5-9b` both fits 64K on-GPU and is the stronger model — switch to it before
> blaming context.

- **It "loses" elements on big/complex pages** (long Gmail threads, dashboards) → the DOM
  is overflowing the 16k context. Switch to a 32k-context light model:
  ```
  # save as web-nav-qwen2.5vl-7b.Modelfile
  FROM qwen2.5vl:7b
  PARAMETER num_ctx 32768
  PARAMETER temperature 0.2
  # then:  ollama create web-nav-qwen2.5vl-7b -f web-nav-qwen2.5vl-7b.Modelfile
  ```
  `qwen2.5vl:7b` is 6 GB (fits with room for 32k context) and was the fastest in benchmark.
  It can also use vision if you turn it on.
- **The task is pure reading/summarizing with no clicking** → that's not an automation job.
  Use Page Assist (reads the current page), not Nanobrowser.

## 6. Reality check

Nanobrowser drives a live, changing UI — even with perfect prompts some runs fail
(layout changes, slow loads, A/B'd buttons). Treat it as "usually works, supervise the
first run of any new task," not "fire and forget." Keep tasks scoped; chain short reliable
tasks rather than one giant 40-step prompt.

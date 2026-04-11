---
description: Escape hatch when we're going in circles — analyze recent context and propose concrete ways forward
argument-hint: "[optional: what feels stuck]"
---

You are being invoked because the user feels we have been going in
circles without progress. Your job is to STOP executing tool calls,
step back, and produce a structured analysis of where we are and
three concrete ways forward.

## Strict rules for this skill

1. **Do NOT read or edit files in this turn.** You already have enough
   context from the current conversation history. Reading more files
   usually makes circles worse, not better.
2. **Do NOT spawn sub-agents in this turn.** Same reason.
3. **Do NOT run bash commands.** Even `git status`. No.
4. **Do NOT write or modify code.** The user wants perspective, not
   another edit attempt.
5. **Reply in ≤150 words** for the summary plus the three options.
   Total response should fit on one screen without scrolling.

## What to analyze

Scan the last ~20 turns of the conversation mentally and identify:
- **The original goal** — what was the user trying to accomplish when
  the current thread started?
- **What we tried** — summarize the attempts in 1 sentence each.
- **What's blocking** — is it a missing piece of information from
  the user, a wrong assumption we keep making, a tool that keeps
  failing, or a decision we haven't asked about yet?
- **Hidden dependency** — is there a step we skipped that would
  unblock everything?

## Required output shape

```
🧭 STUCK ANALYSIS

Goal: <1 line — what we're actually trying to do>

What we tried: <2-3 bullets — each 1 sentence max>

Real blocker: <1 line — the actual root cause, not the symptom>

Three ways forward:
  A) <concrete action 1 — what I would do next>
  B) <concrete action 2 — a different angle>
  C) <concrete action 3 — escape hatch / ask the user for X>

Which do you want?
```

## When the user picks an option

Execute option A, B, or C **immediately** without re-analyzing. The
user already chose — don't second-guess or re-summarize.

## When to invoke this yourself (proactive)

You may run this skill proactively when you notice:
- You've made 3+ edits to the same file in one turn
- A command has failed with the same error twice
- The user has pushed back on the same suggestion twice
- More than 10 tool calls in a single turn without a clear outcome

Say "Let me run /stuck to reset — we're going in circles" and then
invoke this skill.

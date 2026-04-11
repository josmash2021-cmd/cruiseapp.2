---
description: Full release flow — validate, bump, commit, push, deploy backend, prompt for mobile builds
argument-hint: "[optional: custom commit message]"
---

Ship a complete release of Cruise in a single command. This is the
end-of-day / hotfix shortcut that wraps the 10-step manual flow into
one action.

## Pre-flight checks (abort if any fail)

1. `git status` — must have staged or unstaged changes. If working
   tree is clean, print "nothing to ship" and exit.
2. Run `python -m py_compile` on every modified `.py` under `backend/`.
   If any file fails, print the error and ABORT — do not commit broken
   Python.
3. Read the current version from `pubspec.yaml` line 5 and parse the
   build number. Must match `version: 1.0.2+NNN`. If it doesn't, ABORT.
4. If `.env` or `credentials.json` are staged, ABORT — never ship secrets.

## Ship flow

### Step 1: Bump version
- Increment the build number by 1 (1.0.2+293 → 1.0.2+294).
- Edit `pubspec.yaml` line 5 with the new version.
- Stage `pubspec.yaml`.

### Step 2: Generate commit message
- If the user passed a custom message as $ARGUMENTS, use it verbatim.
- Otherwise, run `git diff --staged --stat` and read the file list.
- Classify the change based on which directories were touched:
  - `backend/` only → `chore(backend): ...`
  - `lib/screens/` or `lib/controllers/` → `feat(ui): ...`
  - `lib/services/` → `feat(api): ...`
  - `lib/l10n/` → `fix(i18n): ...`
  - Mixed → `feat: ...`
- Summarize the main change from the diff stat in one short line.
- Append the standard Co-Authored-By: Claude Opus footer.

### Step 3: Commit + push
- `git add` only the files that were already modified (never `git add -A`).
- Create the commit with the message from step 2.
- `git push`. If push fails with conflict, ABORT and tell the user to
  pull+resolve.

### Step 4: Backend deploy
- If `backend/` files are in the commit, run `railway up --detach` and
  capture the build URL.
- Wait 30 seconds.
- Run `railway logs | tail -30` and scan for ERROR / Traceback /
  healthcheck fail.
- If any fatal pattern appears, print the error and tell the user to
  investigate.

### Step 5: Report and prompt for mobile builds
Print the final summary in this exact shape:

```
🚢 SHIPPED 1.0.2+NNN

📦 Commit: <short sha>
🐍 Backend: <deployed / skipped — no backend changes>
🌐 Railway build: <url or "healthy">

⏳ Next — your job:
  📱 Android:  shorebird patch or release (you know which)
  🍎 iOS:      trigger Codemagic for 1.0.2+NNN

Smoke-test on device when the builds land.
```

## Hard rules

- **NEVER** use `git add -A` or `git add .` — always explicit file paths.
- **NEVER** use `--no-verify` or bypass hooks.
- **NEVER** force-push to main.
- **NEVER** run `flutter build apk` or `flutter build ipa` manually —
  the user has Shorebird + Codemagic for that.
- If any pre-flight check fails, ABORT with a clear reason — do not
  attempt partial ships.
- Push directly to `main` only. If on another branch, print the branch
  name and ABORT with "you're not on main — switch first".

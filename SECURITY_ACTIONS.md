# 🔒 SECURITY ACTIONS — CruiseApp

> **Audit Date:** 2026-06-04  
> **Auditor:** Kimi Code CLI  
> **Scope:** Full repository audit + immediate safe fixes  

---

## ✅ FIXED NOW (Safe code changes, no secrets rotation required)

### 1. `backend/scripts/cancel_via_api.py` — Removed hardcoded production credentials
**Before:** `DISPATCH_API_KEY` and `HMAC_SECRET` were hardcoded in the script.  
**After:** Script now reads from environment variables (`CRUISE_DISPATCH_API_KEY`, `CRUISE_HMAC_SECRET`) and raises `RuntimeError` if they are missing.  
**Impact:** Zero functional change; script users must now `export` the vars before running.

### 2. `backend/.env.template` — Removed real OpenAI API key
**Before:** Line 67 contained a real `sk-proj-...` OpenAI key.  
**After:** Replaced with placeholder `sk-proj-your-openai-api-key-here`.  
**Impact:** Template is safe to share; no runtime impact.

### 3. `backend/services/redis_cache.py` — Eliminated `pickle` (RCE vector)
**Before:** Used `pickle.dumps` / `pickle.loads` as fallback for non-JSON values.  
**After:** `pickle` completely removed. `_serialize()` raises `TypeError` for non-JSON-serializable values. `_deserialize()` logs a warning and returns `None` for legacy pickle-encoded entries (self-purging).  
**Impact:** Any code caching non-JSON objects will now raise at write time. All existing cached pickle entries will silently expire on next read. **Verify your cached data types.**

### 4. `backend/main.py` — Hardened CORS fallback
**Before:** If `CORS_ORIGINS` env var was unset, the default list included `http://localhost:3000` and `http://localhost:8000`.  
**After:** Localhost origins are ONLY included when `DEBUG=1` (or `true`/`yes`) is set. In production without `CORS_ORIGINS`, only the three production domains are allowed.  
**Impact:** Safer default for production; local dev still works with `DEBUG=1`.

---

## 🔄 PENDING — Requires your action (secret rotation + CI/CD changes)

### P1. Rotate exposed secrets immediately
The following secrets are still hardcoded in source files that are needed for builds. **Rotate them in their respective dashboards** and move them to CI/CD injection.

| Secret | Location | Action |
|--------|----------|--------|
| Firebase Web API key | `lib/firebase_options.dart:21` | Rotate in Firebase Console → Project Settings → Web API Key. Then inject at build time. |
| Firebase Android API key | `lib/firebase_options.dart:32`, `android/app/google-services.json` | Rotate in Firebase Console → Android app. Regenerate `google-services.json`. Consider using CI/CD to inject it. |
| Firebase iOS API key | `lib/firebase_options.dart:41`, `ios/Runner/GoogleService-Info.plist` | Rotate in Firebase Console → iOS app. Regenerate `GoogleService-Info.plist`. |
| Google Maps API key | `web/index.html:53` | Restrict key to `cruiseinride.com` referrer in Google Cloud Console. Move to env var injected at build. |
| Stripe Live publishable key | `assets/pay/google_pay.yaml:24`, `assets/pay/default_google_pay_config.json:19` | Rotate in Stripe Dashboard. Generate these files dynamically in CI/CD using `--dart-define` or a pre-build script. |

### P2. Clean git history of old secrets
Commits prior to this audit contain leaked secrets (see `AUDIT_REPORT.md` for full list). Use **BFG Repo-Cleaner** or `git-filter-repo` to purge them from history **before** making the repository public or sharing it.

Example:
```bash
# Install git-filter-repo
pip install git-filter-repo

# Replace a secret across all history
git filter-repo --replace-text <(echo 'OLD_SECRET==>REDACTED')
```

### P3. Migrate `python-jose` → `PyJWT`
`backend/requirements.txt` pins `python-jose[cryptography]==3.4.0`. While 3.4.0 patches the known JWT bypass CVE, `PyJWT` is the community-recommended, better-maintained alternative.  
**Scope:** ~15 files import `from jose import jwt`.  
**Effort:** Medium (requires updating imports, exception handling `JWTError` → `jwt.InvalidTokenError`, and full test pass).  
**Risk:** Low if done with test coverage.

### P4. Endpoint `/photos/{filename}` — Evaluate signed URLs
The profile-photo serving endpoint in `backend/routers/auth.py` is intentionally public (no auth) so the Flutter app can display avatars without an auth header.  
**Recommendation:** Keep it public for now, but add:
- `Cache-Control: public, max-age=3600` (safe, reduces backend load)
- Rate-limiting by IP on this path (already partially covered by global rate limiting)
- **Future:** Migrate to Firebase Storage signed URLs or CloudFront signed URLs for private photos.

### P5. Move Firebase config files out of repo
`android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist` contain project metadata. While Firebase API keys for mobile are not truly secret (they ship in the APK/IPA), keeping these files in git leaks project IDs, app IDs, and certificate hashes.  
**Recommendation:** Add them to `.gitignore` and inject them via CI/CD (Codemagic environment files, GitHub Secrets, or `base64` env vars).

### P6. Enable secret scanning
Enable **GitHub Advanced Security** → Secret scanning on this repository to catch future leaks before they reach `main`.

---

## 🛡️ SECURITY POSTURE SUMMARY

| Layer | Status |
|-------|--------|
| Backend auth (HMAC + JWT + bcrypt) | ✅ Strong |
| SQL injection mitigation (SQLAlchemy ORM) | ✅ Strong |
| Rate limiting + IP blacklist | ✅ Strong |
| Input sanitization + XSS rejection | ✅ Strong |
| Audit logging with hash chain | ✅ Strong |
| Redis serialization (pickle removed) | ✅ Fixed |
| CORS production defaults | ✅ Fixed |
| Hardcoded backend secrets | ✅ Fixed |
| Mobile API key exposure | ⚠️ Rotate + CI/CD |
| Git history cleanliness | ⚠️ Clean required |
| Dependency `python-jose` | ⚠️ Migrate to PyJWT |

---

## 📋 VERIFICATION CHECKLIST

- [ ] Rotated Firebase API keys (Web, Android, iOS)
- [ ] Rotated Google Maps API key and restricted referrers
- [ ] Rotated Stripe publishable key
- [ ] Removed old secrets from git history (`git-filter-repo`)
- [ ] Added `google-services.json` and `GoogleService-Info.plist` to `.gitignore`
- [ ] Injected mobile configs via CI/CD secrets
- [ ] Migrated `python-jose` → `PyJWT` + all tests pass
- [ ] Enabled GitHub secret scanning

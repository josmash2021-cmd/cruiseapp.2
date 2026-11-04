#!/usr/bin/env bash
# Runs firestore.rules against the local Firestore emulator — a "demo-"
# project id, so nothing ever reaches production. Needs Java 11+ (the
# emulator is a JAR): set JAVA_HOME, or keep the portable JRE at
# ~/tools/jre21 (Eclipse Temurin).
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${JAVA_HOME:-}" ] && ls "$HOME"/tools/jre21/*/bin/java* >/dev/null 2>&1; then
  JAVA_HOME="$(dirname "$(dirname "$(ls "$HOME"/tools/jre21/*/bin/java* | head -1)")")"
  export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
fi
[ -d node_modules ] || npm install --no-audit --no-fund
RULES="${RULES:-}" firebase emulators:exec --only firestore --project demo-cruise-rules \
  --config firebase.json "npm test"

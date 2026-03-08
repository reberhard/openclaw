#!/usr/bin/env bash
# auto-update.sh — Automated OpenClaw update with AI risk evaluation
# Runs daily at 06:00 via com.openclaw.auto-update LaunchAgent
#
# Flow: version check → gather context → AI evaluation → update/notify → smoke test
#
# Usage:
#   auto-update.sh           Run normal update check
#   auto-update.sh --force   Skip version check, run full pipeline (for testing)

set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────

OPENCLAW_DIR="${HOME}/openclaw"
NPM_OPENCLAW_DIR="${HOME}/.nvm/versions/node/v24.13.0/lib/node_modules/openclaw"
LOG_FILE="${HOME}/openclaw/logs/auto-update.log"
LOCK_DIR="/tmp/openclaw-auto-update.lock"
SLACK_CHANNEL="#openclaw"

GATEWAY_LOG="${HOME}/.openclaw/logs/gateway.log"
GATEWAY_ERR_LOG="${HOME}/.openclaw/logs/gateway.err.log"
GATEWAY_LABEL="ai.openclaw.gateway"

NODE="${HOME}/.nvm/versions/node/v24.13.0/bin/node"
NPM="${HOME}/.nvm/versions/node/v24.13.0/bin/npm"
GH="/opt/homebrew/bin/gh"
CLAWDBOT="${HOME}/bin/clawdbot"
CLAUDE="${HOME}/.nvm/versions/node/v24.13.0/bin/claude"

# Flags
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
fi

# State
installed_version=""
latest_version=""
rollback_version=""
release_notes=""
changelog_excerpt=""
config_snapshot=""
risk_level=""
recommendation=""
ai_summary=""
ai_response=""

# ─── LOGGING ─────────────────────────────────────────────────────────────────

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

die() {
  log "FATAL: $*"
  notify_slack "OpenClaw auto-update FATAL: $*" || true
  exit 1
}

# ─── LOCK ────────────────────────────────────────────────────────────────────

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "${LOCK_DIR}/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
    return 0
  fi

  local existing_pid
  existing_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    log "Already running (pid $existing_pid). Exiting."
    exit 0
  fi

  # Stale lock — reclaim
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  echo "$$" > "${LOCK_DIR}/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

# ─── NOTIFICATIONS ───────────────────────────────────────────────────────────

notify_slack() {
  local message="$1"

  if [[ -x "$CLAWDBOT" ]]; then
    "$CLAWDBOT" message send --channel slack --target "$SLACK_CHANNEL" --message "$message" 2>&1 || {
      log "WARN: clawdbot notification failed"
    }
  else
    log "WARN: clawdbot not found at $CLAWDBOT, notification skipped"
  fi

  # Always log the message content regardless of delivery
  log "NOTIFICATION: $message"
}

# ─── STEP 1: VERSION CHECK ──────────────────────────────────────────────────

version_check() {
  log "Checking for updates..."

  installed_version="$(
    "$NODE" -e "
      const p = require('${NPM_OPENCLAW_DIR}/package.json');
      process.stdout.write(p.version);
    " 2>/dev/null || echo ""
  )"

  latest_version="$(
    "$NPM" show openclaw dist-tags.latest 2>/dev/null || echo ""
  )"

  if [[ -z "$latest_version" || -z "$installed_version" ]]; then
    die "Could not determine versions (installed=${installed_version:-unknown} latest=${latest_version:-unknown})"
  fi

  if [[ "$installed_version" == "$latest_version" ]]; then
    if [[ "$FORCE" == true ]]; then
      log "Already at latest ($installed_version) but --force specified. Running full pipeline."
    else
      log "Already at latest: $installed_version. Nothing to do."
      exit 0
    fi
  else
    log "Update available: $installed_version → $latest_version"
  fi
}

# ─── STEP 2: GATHER CONTEXT ─────────────────────────────────────────────────

gather_context() {
  log "Gathering release context..."

  # GitHub release notes
  release_notes="$(
    "$GH" release view "v${latest_version}" -R openclaw/openclaw \
      --json body -q .body 2>/dev/null || echo "(release notes unavailable)"
  )"

  # Fetch CHANGELOG from GitHub raw (the installed npm package has the OLD version's changelog)
  local escaped_ver="${latest_version//./\\.}"
  changelog_excerpt="$(
    "$GH" api "repos/openclaw/openclaw/contents/CHANGELOG.md" \
      -H "Accept: application/vnd.github.raw" 2>/dev/null \
      | awk "
        /^## ${escaped_ver}/{found=1}
        found{print; if (/^## / && !/^## ${escaped_ver}/) exit}
      " \
      | head -100 || echo "(CHANGELOG unavailable from GitHub)"
  )"
  # Fallback: if GitHub API failed, try the installed copy (may not have the new version's section)
  if [[ -z "$changelog_excerpt" || "$changelog_excerpt" == "(CHANGELOG unavailable from GitHub)" ]]; then
    if [[ -f "${NPM_OPENCLAW_DIR}/CHANGELOG.md" ]]; then
      changelog_excerpt="$(
        awk "
          /^## ${escaped_ver}/{found=1}
          found{print; if (/^## / && !/^## ${escaped_ver}/) exit}
        " "${NPM_OPENCLAW_DIR}/CHANGELOG.md" 2>/dev/null \
          | head -100 || echo "(CHANGELOG section not found)"
      )"
    fi
  fi
  changelog_excerpt="${changelog_excerpt:-(no CHANGELOG available)}"

  # Redacted config snapshot
  config_snapshot="$(
    /opt/homebrew/bin/python3 -c "
import json, sys
try:
    with open('${HOME}/.openclaw/openclaw.json') as f:
        d = json.load(f)
    def redact(obj, depth=0):
        if depth > 10: return obj
        if isinstance(obj, dict):
            return {k: '<REDACTED>' if any(s in k.lower() for s in ['token','secret','key','password','auth']) else redact(v, depth+1) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [redact(i, depth+1) for i in obj]
        return obj
    print(json.dumps(redact(d), indent=2))
except Exception as e:
    print(f'(config unavailable: {e})')
" 2>/dev/null
  )"

  log "Context gathered: release_notes=${#release_notes}chars changelog=${#changelog_excerpt}chars config=${#config_snapshot}chars"
}

# ─── STEP 3: AI EVALUATION ──────────────────────────────────────────────────

ai_evaluate() {
  log "Starting AI evaluation..."

  local eval_prompt
  eval_prompt="$(cat <<'PROMPT_HEADER'
You are evaluating a software update for the OpenClaw AI messaging gateway. Produce a structured JSON assessment.

## What Is OpenClaw

OpenClaw is an AI messaging gateway that routes Slack messages to Claude agents. It runs as a macOS LaunchAgent on a personal Mac. Three production agents depend on it 24/7: Clawd (personal ops), Alex (sales), Steve (product). Downtime = lost messages, no AI responses.

## Architecture

The gateway runs as a node process via LaunchAgent (ai.openclaw.gateway). Two critical plugins hook into the gateway runtime:
1. Pre-Flight Validator — uses the 'message_sending' hook to block outbound violations. If this hook name/payload changes, messages are sent unvalidated.
2. Context Restorer — uses the 'before_agent_start' hook for every agent turn. If this hook name/payload changes, agents lose context after compaction.

A custom workspace-context bundled hook is installed at dist/bundled/workspace-context/. It is overwritten by npm updates and must be re-installed.

## Known Risk Areas

1. HOOK API CHANGES: If 'message_sending' or 'before_agent_start' hook names or payload schemas change, plugins fail SILENTLY.
2. SANDBOX MODE RESET: Config has agents.defaults.sandbox.mode: "off" because Docker is not installed. If the update resets this or adds a migration that changes it, the gateway crash-loops with "spawn docker ENOENT".
3. CONFIG MIGRATION: If openclaw runs a config migration on startup that rewrites fields the plugins depend on.
4. BREAKING CHANGES: Anything labeled "BREAKING" in release notes.
5. SECURITY PATCHES: Items under "Security" or labeled as security fixes should be applied promptly.

PROMPT_HEADER
)"

  eval_prompt+="
## Current Config (Redacted)

${config_snapshot}

## Update Being Evaluated

Current version: ${installed_version}
New version: ${latest_version}

## Release Notes for ${latest_version}

${release_notes}

## CHANGELOG Excerpt

${changelog_excerpt}

## Task

Respond with ONLY valid JSON (no markdown fences, no text outside the JSON):

{
  \"risk_level\": \"low\" | \"medium\" | \"high\",
  \"recommendation\": \"auto_update\" | \"wait_for_user\",
  \"summary\": \"1-2 sentence plain English summary\",
  \"breaking_changes\": [\"list or empty\"],
  \"security_patches\": [\"list or empty\"],
  \"affected_areas\": [\"hooks\", \"config\", \"sandbox\", \"slack\", \"agent_runtime\", etc.],
  \"hook_api_risk\": \"none\" | \"possible\" | \"confirmed\",
  \"reasoning\": \"2-3 sentences explaining the risk assessment\"
}

Decision rules:
- No breaking changes, no hook API changes, minor fixes → low + auto_update
- Security patches with no breaking changes → medium + auto_update (security > caution)
- Any BREAKING change, hook API change, config migration, sandbox/auth change → high + wait_for_user
- Release notes unavailable → medium + auto_update (assume safe, note uncertainty)
"

  # Run Claude with a 120s timeout (macOS has no `timeout` command)
  local tmp_response
  tmp_response="$(mktemp)"
  env -u CLAUDECODE "$CLAUDE" -p \
    --model sonnet \
    --output-format text \
    --no-session-persistence \
    <<< "$eval_prompt" > "$tmp_response" 2>/dev/null &
  local claude_pid=$!

  local waited=0
  while kill -0 "$claude_pid" 2>/dev/null; do
    if (( waited >= 120 )); then
      kill "$claude_pid" 2>/dev/null || true
      wait "$claude_pid" 2>/dev/null || true
      log "WARN: Claude CLI timed out after 120s"
      rm -f "$tmp_response"
      risk_level="unknown"
      recommendation="wait_for_user"
      ai_summary="AI evaluation timed out. Manual review recommended."
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$claude_pid" 2>/dev/null || true

  ai_response="$(cat "$tmp_response" 2>/dev/null || echo "")"
  rm -f "$tmp_response"

  log "AI raw response (${#ai_response} chars): $(echo "$ai_response" | head -5)"

  if [[ -z "$ai_response" ]]; then
    log "WARN: Claude CLI returned empty response, defaulting to wait_for_user"
    risk_level="unknown"
    recommendation="wait_for_user"
    ai_summary="AI evaluation failed (empty response). Manual review recommended."
    return
  fi

  # Extract JSON and parse all fields in one python3 call
  # NOTE: Script goes to a temp file because heredoc + pipe conflict for stdin.
  # The pipe delivers ai_response data; the file provides the code.
  local py_script
  py_script="$(mktemp)"
  cat > "$py_script" << 'PYEOF'
import json, sys, re

raw = sys.stdin.read()
d = None

# Try parsing as-is
try:
    d = json.loads(raw.strip())
except:
    pass

# Strip markdown fencing and extract JSON object
if d is None:
    cleaned = re.sub(r'```\w*\n?', '', raw)
    match = re.search(r'\{.*\}', cleaned, re.DOTALL)
    if match:
        try:
            d = json.loads(match.group())
        except:
            pass

if d and isinstance(d, dict):
    rl = d.get('risk_level', 'high')
    rec = d.get('recommendation', 'wait_for_user')
    summary = d.get('summary', 'No summary provided').replace('\n', ' ').replace('\t', ' ')
    print(f'{rl}\t{rec}\t{summary}')
else:
    print('high\twait_for_user\tAI response could not be parsed as JSON')
PYEOF

  local ai_parsed
  ai_parsed="$(echo "$ai_response" | /opt/homebrew/bin/python3 "$py_script")"
  rm -f "$py_script"
  ai_parsed="${ai_parsed:-high	wait_for_user	AI evaluation failed (python3 error)}"

  IFS=$'\t' read -r risk_level recommendation ai_summary <<< "$ai_parsed"

  # Fallback if read/python failed
  risk_level="${risk_level:-high}"
  recommendation="${recommendation:-wait_for_user}"
  ai_summary="${ai_summary:-AI evaluation produced unparseable response}"

  log "AI evaluation: risk=$risk_level recommendation=$recommendation"
  log "AI summary: $ai_summary"
}

# ─── STEP 4: DECISION ───────────────────────────────────────────────────────

make_decision() {
  if [[ "$recommendation" == "auto_update" ]]; then
    log "AI recommends auto-update. Proceeding."
    return 0
  fi

  log "AI recommends waiting. Sending notification."
  notify_slack "*OpenClaw Update Available — Review Requested*

Current: \`${installed_version}\` → New: \`${latest_version}\`
Risk: *${risk_level}*

${ai_summary}

To update manually:
\`\`\`
npm install -g openclaw@${latest_version}
~/openclaw/scripts/apply-threading-patches.sh
launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway
\`\`\`"
  exit 0
}

# ─── STEP 5: UPDATE ─────────────────────────────────────────────────────────

do_update() {
  rollback_version="$installed_version"

  if [[ "$FORCE" == true && "$installed_version" == "$latest_version" ]]; then
    log "FORCE mode: skipping npm install (already at $installed_version). Re-applying patches only."
  else
    log "Installing openclaw@${latest_version}..."
    if ! "$NPM" install -g "openclaw@${latest_version}" 2>&1; then
      die "npm install failed. Old version ($rollback_version) still in place."
    fi
    log "npm install succeeded."
  fi

  log "Re-applying patches..."
  if ! bash "${OPENCLAW_DIR}/scripts/apply-threading-patches.sh" 2>&1; then
    log "WARN: apply-threading-patches.sh reported issues (may be fine if upstream fixed the patterns)"
  fi
}

# ─── STEP 6: RESTART ────────────────────────────────────────────────────────

# Tracked across restart → smoke test
err_log_lines_before=0

restart_gateway() {
  # Record current error log size so smoke test only checks NEW errors
  err_log_lines_before="$(wc -l < "$GATEWAY_ERR_LOG" 2>/dev/null || echo 0)"

  log "Restarting gateway..."
  if ! launchctl kickstart -k "gui/$(id -u)/${GATEWAY_LABEL}" 2>&1; then
    die "launchctl kickstart failed"
  fi
  log "Gateway restart initiated. Waiting 10s for startup..."
  sleep 10
}

# ─── STEP 7: SMOKE TEST ─────────────────────────────────────────────────────

smoke_test() {
  log "Running smoke tests..."

  # Test 1: Process alive
  local pid
  pid="$(launchctl list | grep "$GATEWAY_LABEL" | awk '{print $1}')"
  if [[ -z "$pid" || "$pid" == "-" ]]; then
    smoke_failed "Gateway not running after restart (PID missing)"
    return 1
  fi
  log "  [PASS] Gateway running (PID $pid)"

  # Test 2: Slack connected
  if tail -30 "$GATEWAY_LOG" 2>/dev/null | grep -q "socket mode connected"; then
    log "  [PASS] Slack socket mode connected"
  else
    log "  [WARN] 'socket mode connected' not in last 30 log lines (may still be starting)"
  fi

  # Test 3: No crash indicators (only check lines written AFTER restart)
  local new_errors
  local err_log_lines_now
  err_log_lines_now="$(wc -l < "$GATEWAY_ERR_LOG" 2>/dev/null || echo 0)"
  if (( err_log_lines_now > err_log_lines_before )); then
    new_errors="$(tail -n +"$((err_log_lines_before + 1))" "$GATEWAY_ERR_LOG" 2>/dev/null || echo "")"
  else
    new_errors=""
  fi
  if echo "$new_errors" | grep -qE "Uncaught exception|spawn.*ENOENT|Cannot find module"; then
    smoke_failed "Critical errors in gateway.err.log since restart"
    return 1
  fi
  log "  [PASS] No critical errors in err.log since restart"

  # Test 4: PID stability (30s)
  log "  Checking PID stability (30s)..."
  sleep 30
  local pid_after
  pid_after="$(launchctl list | grep "$GATEWAY_LABEL" | awk '{print $1}')"
  if [[ "$pid" != "$pid_after" ]]; then
    smoke_failed "PID changed ($pid → $pid_after) — crash-looping"
    return 1
  fi
  log "  [PASS] PID stable after 30s"

  log "All smoke tests passed."
  return 0
}

smoke_failed() {
  local reason="$1"
  log "SMOKE TEST FAILED: $reason"
  log "Rolling back to openclaw@${rollback_version}..."

  "$NPM" install -g "openclaw@${rollback_version}" 2>&1 || log "WARN: rollback npm install failed"
  bash "${OPENCLAW_DIR}/scripts/apply-threading-patches.sh" 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/${GATEWAY_LABEL}" 2>/dev/null || true
  sleep 5

  notify_slack "*OpenClaw Auto-Update FAILED — Rolled Back*

Attempted: \`${rollback_version}\` → \`${latest_version}\`
Reason: ${reason}
Action: Rolled back to \`${rollback_version}\`

Check logs: \`tail -50 ~/openclaw/logs/auto-update.log\`"
}

# ─── STEP 8: NOTIFY SUCCESS ─────────────────────────────────────────────────

notify_success() {
  local new_ver
  new_ver="$(
    "$NODE" -e "
      const p = require('${NPM_OPENCLAW_DIR}/package.json');
      process.stdout.write(p.version);
    " 2>/dev/null || echo "$latest_version"
  )"

  notify_slack "*OpenClaw Updated* \`${rollback_version}\` → \`${new_ver}\`

Risk: ${risk_level} | ${ai_summary}

Patches re-applied, gateway restarted, smoke tests passed."
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  exec >> "$LOG_FILE" 2>&1

  if [[ "$FORCE" == true ]]; then
    log "===== auto-update.sh started (--force) ====="
  else
    log "===== auto-update.sh started ====="
  fi

  acquire_lock
  version_check
  gather_context
  ai_evaluate
  make_decision
  do_update
  restart_gateway
  if smoke_test; then
    notify_success
  fi

  log "===== auto-update.sh complete ====="
}

main "$@"

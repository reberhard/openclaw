#!/bin/bash
# apply-threading-patches.sh
# Re-applies local patches to the installed openclaw npm binary.
# Run this after: npm update -g openclaw
#
# As of 2026.2.25, only 1 patch is needed:
# 1. dock-*.js — Handle bare Slack channel IDs (not just "channel:" prefix)
#    for currentChannelId resolution in threading tool context
#
# Patches NO LONGER needed (built-in since 2026.2.22+):
# - message-action-runner.js auto-thread injection (built-in via outbound threading)
# - reply-payloads.js replyToMode="all" auto-threading (built-in)
# - dispatch.js message:inbound hook (context-loader uses agent:bootstrap, not message:inbound)
#
# Also installs context-loader bundled hook (not upstream).

set -euo pipefail

DIST="/Users/eberhard/.nvm/versions/node/v24.13.0/lib/node_modules/openclaw/dist"

if [ ! -d "$DIST" ]; then
  echo "ERROR: openclaw dist not found at $DIST"
  exit 1
fi

echo "Applying patches to $DIST ..."

# --- Patch 1: dock-*.js — Handle bare Slack channel IDs ---
PATCHED=0
for file in "$DIST"/dock-*.js; do
  if [ -f "$file" ]; then
    if grep -q 'currentChannelId: params.context.To?.startsWith("channel:") ? params.context.To.slice(8) : void 0' "$file" 2>/dev/null; then
      python3 -c "
with open('$file', 'r') as f:
    content = f.read()
old = 'currentChannelId: params.context.To?.startsWith(\"channel:\") ? params.context.To.slice(8) : void 0'
new = 'currentChannelId: (() => { const rawTo = params.context.To; if (typeof rawTo !== \"string\") return void 0; if (rawTo.startsWith(\"channel:\")) return rawTo.slice(8); if (rawTo.startsWith(\"C\")) return rawTo; return void 0; })()'
if old in content:
    content = content.replace(old, new)
    with open('$file', 'w') as f:
        f.write(content)
    print(f'  [OK] $(basename $file) — patched bare channel ID handling')
else:
    print(f'  [SKIP] $(basename $file) — pattern not found')
"
      PATCHED=$((PATCHED + 1))
    else
      echo "  [SKIP] $(basename $file) — already patched or pattern changed"
    fi
  fi
done
if [ "$PATCHED" -eq 0 ]; then
  echo "  [WARN] No dock-*.js files needed patching"
fi

# --- Install workspace-context bundled hook (bootstrap working-context injection) ---
# The handler.js imports internal chunks by hash (e.g., subsystem-DhjIxims.js).
# These hashes change every release, so we dynamically resolve the correct filenames
# by grepping for the exported symbols we need.
HOOK_DIR="$DIST/bundled/workspace-context"
HOOK_SRC_DIR="/Users/eberhard/openclaw/scripts/workspace-context-hook"
if [ -d "$HOOK_SRC_DIR" ]; then
  mkdir -p "$HOOK_DIR"
  cp "$HOOK_SRC_DIR/handler.js" "$HOOK_DIR/handler.js"
  cp "$HOOK_SRC_DIR/HOOK.md" "$HOOK_DIR/HOOK.md"

  # Resolve current chunk filenames from the dist directory
  # (|| true prevents set -e from killing the script if grep finds no matches)
  SUBSYSTEM_FILE="$(grep -l 'isAgentBootstrapEvent' "$DIST"/subsystem-*.js 2>/dev/null | head -1 || true)"
  CONFIG_FILE="$(grep -l 'resolveHookConfig' "$DIST"/config-*.js 2>/dev/null | head -1 || true)"
  SESSKEY_FILE="$(grep -l 'isSubagentSessionKey' "$DIST"/session-key-*.js 2>/dev/null | grep -v plugin-sdk | head -1 || true)"

  if [[ -n "$SUBSYSTEM_FILE" && -n "$CONFIG_FILE" && -n "$SESSKEY_FILE" ]]; then
    SUBSYSTEM_BASE="$(basename "$SUBSYSTEM_FILE")"
    CONFIG_BASE="$(basename "$CONFIG_FILE")"
    SESSKEY_BASE="$(basename "$SESSKEY_FILE")"

    # Replace chunk references in the installed handler.js
    sed -i '' \
      -e "s|subsystem-[A-Za-z0-9_-]*\.js|${SUBSYSTEM_BASE}|g" \
      -e "s|config-[A-Za-z0-9_-]*\.js|${CONFIG_BASE}|g" \
      -e "s|session-key-[A-Za-z0-9_-]*\.js|${SESSKEY_BASE}|g" \
      "$HOOK_DIR/handler.js"

    echo "  [OK] workspace-context bundled hook installed (chunks: ${SUBSYSTEM_BASE}, ${CONFIG_BASE}, ${SESSKEY_BASE})"
  else
    echo "  [WARN] workspace-context installed but could not resolve chunk hashes — handler may fail to load"
    echo "         subsystem=${SUBSYSTEM_FILE:-NOT FOUND} config=${CONFIG_FILE:-NOT FOUND} session-key=${SESSKEY_FILE:-NOT FOUND}"
  fi
else
  if [ -f "$HOOK_DIR/handler.js" ]; then
    echo "  [SKIP] workspace-context already installed"
  else
    echo "  [WARN] workspace-context hook source not found at $HOOK_SRC_DIR"
  fi
fi

echo ""
echo "Done. Restart the gateway for changes to take effect:"
echo "  launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist"
echo "  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist"

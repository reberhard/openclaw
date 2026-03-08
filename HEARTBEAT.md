# Clawd Heartbeat (Selective-Recall Mode)

## Priority 0 — Situational Awareness (EVERY HEARTBEAT)

1. Read `~/clawd/memory/channel-pulse.json`.
2. Internalize the status of all channels (#finance, #life-aviation, etc.).
3. **DO NOT** read full context files unless the pulse status is "ACTION_REQUIRED" or Ryan asks a specific question.

## Priority 1 — The "Pulse" Maintenance (HOURLY)

Run `python3 ~/clawd/scripts/update-pulse.py`.
This script updates the manifest from your Obsidian notes, Gmail, and WhatsApp logs without spawning an LLM session.

## Priority 2 — Intent Queue

Process `memory/intent-queue.md` only for items marked "URGENT".

## Priority 3 — Token Safety

Check LiteLLM budget. If daily spend > $9.00, disable all background polling immediately.

{\rtf1\ansi\ansicpg1252\cocoartf2868
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
{\*\expandedcolortbl;;}
\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\pard\tx720\tx1440\tx2160\tx2880\tx3600\tx4320\tx5040\tx5760\tx6480\tx7200\tx7920\tx8640\pardirnatural\partightenfactor0

\f0\fs24 \cf0 # MISSION CONTROL PATCH: MARCH 2026\
**Goal:** Stop token drain via cooldowns and implement dynamic model routing.\
\

## 1. ORIENTATION COOLDOWN (Logic Fix)\

**Target File:** `packages/clawdbot/index.js`\
Implement a 5-minute cooldown to stop orientation spam.\
\

- **Initialization:** Add `const lastOrientationAt = new Map();` at the top of the file, outside any functions.\
- **Logic:** Inside the `before_agent_start` hook:\
  - Calculate `const now = Date.now();`.\
  - Get the last run time for the current `sessionKey`: `const lastRun = lastOrientationAt.get(event.sessionKey) || 0;`.\
  - If `now - lastRun < 300000` (5 minutes), log "Skipping orientation (cooldown)" and return early.\
- **Gating (Fail-Closed):** If `event.messageCount === -1` or `event.prevCount === -1`, log "Skipping orientation (invalid signal)" and return early.\
- **Persistence:** If proceeding, update the map: `lastOrientationAt.set(event.sessionKey, now);`.\
  \

## 2. DYNAMIC MODEL ROUTING (Tiering Fix)\

**Target File:** `../.openclaw/openclaw.json`\
Move Steve and Alex to virtual "hybrid" models to save credits.\
\

- **Action:** Update the `agents` list.\
- **Steve:** Change `model` from "anthropic/claude-opus-4-5" to `"steve-hybrid"`.\
- **Alex:** Change `model` from "anthropic/claude-opus-4-5" to `"alex-hybrid"`.\
- **Clawd:** Ensure model remains `"anthropic/claude-opus-4-5"`.\
  \

## 3. TELEMETRY SCRIPT (Diagnostics)\

**Action:** Create a new file `~/clawd/scripts/token-audit.py`.\

- **Function:** Parse `~/clawd/memory/preflight-validator.jsonl` and `gateway.log`.\
- **Calculation:** Sum input/output tokens per sessionKey for the last 48 hours.\
- **Output:** Print a table with SessionKey, Message Count, and Estimated Cost ($15/1M in, $75/1M out).}

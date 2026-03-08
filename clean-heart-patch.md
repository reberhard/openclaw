{\rtf1\ansi\ansicpg1252\cocoartf2868
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
{\*\expandedcolortbl;;}
\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\pard\tx720\tx1440\tx2160\tx2880\tx3600\tx4320\tx5040\tx5760\tx6480\tx7200\tx7920\tx8640\pardirnatural\partightenfactor0

\f0\fs24 \cf0 # MISSION CONTROL: CLEAN HEART & MONITOR PURGE\
**Goal:** Stop the 429 Rate Limit Death Loop by removing stale monitors and staggering background tasks.\
\

## 1. PURGE STALE MONITORS\

**File:** `clawd/MONITORS.md`\

- **Action:** Delete all content under "1. Sam Kronfeld" and "2. Eric Puritsky".\
- **Status:** Set these to "INACTIVE / CLOSED".\
  \

## 2. STAGGER HEARTBEAT LOGIC\

**File:** `migration-staging/clawd/HEARTBEAT.md`\

- **Action:** Change "EVERY HEARTBEAT" triggers for the following to "HOURLY":\
  - **Comms Triage (Priority #1)**\
  - **Daily Intel Scan (Priority #3.5)**\
  - **Gauge Health Check (Priority #2.5)**\
- **Action:** Completely remove the "Rose Ave email monitor" bash script triggers.\
- **Action:** Completely remove the `sam-kronfeld-monitor.sh` references.\
  \

## 3. FAIL-SAFE RE-ROUTING\

**File:** `migration-staging/clawd/HEARTBEAT.md`\

- **Update:** Ensure any remaining `web_search` or `prospector` calls are wrapped in a check: "Only run if LiteLLM budget < $9.50".}

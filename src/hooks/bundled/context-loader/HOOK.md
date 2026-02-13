---
name: context-loader
description: "Load per-channel working context and structured memory queries into agent bootstrap"
metadata:
  {
    "openclaw":
      {
        "emoji": "🧠",
        "events": ["agent:bootstrap"],
        "requires": { "config": ["hooks.internal.entries.context-loader.enabled"] },
        "install": [{ "id": "bundled", "kind": "bundled", "label": "Bundled with OpenClaw" }],
      },
  }
---

# Context Loader Hook

Loads per-channel working context files and executes structured memory queries at agent bootstrap time.

## What It Does

1. Parses the channel name from the session key (e.g., `slack`, `whatsapp`, `telegram`)
2. Reads `{workspaceDir}/memory/working-context/{channel}.md` if it exists
3. If the file contains a `## Boot Queries` section, extracts and executes each `memory-structured.py` command via shell
4. If the file contains a `## Required Docs` section listing Obsidian vault paths, reads and appends those files (truncated to 5000 chars each)
5. Combines everything into a synthetic `CONTEXT.md` bootstrap file

## Configuration

```json
{
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "context-loader": {
          "enabled": true
        }
      }
    }
  }
}
```

## Requirements

- `hooks.internal.entries.context-loader.enabled` must be set to `true`

## Enable

```bash
openclaw hooks enable context-loader
```

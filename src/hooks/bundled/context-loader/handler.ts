import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import type { WorkspaceBootstrapFileName } from "../../../agents/workspace.js";
import { isSubagentSessionKey } from "../../../routing/session-key.js";
import { resolveHookConfig } from "../../config.js";
import { isAgentBootstrapEvent, type HookHandler } from "../../hooks.js";

const HOOK_KEY = "context-loader";
const EXEC_TIMEOUT_MS = 5_000;
const DOC_MAX_CHARS = 5_000;
const OBSIDIAN_VAULT = path.join(process.env.HOME ?? "/Users/eberhard", "Obsidian-Vault");

interface SessionKeyInfo {
  platform: string;
  peerKind?: string;
  peerId?: string;
}

function parseSessionKeyInfo(sessionKey: string): SessionKeyInfo | undefined {
  // Session keys: "agent:{agentId}:{platform}:{peerKind}:{peerId}" or "agent:{agentId}:main"
  // Thread suffix may also be present: "...:thread:{threadTs}"
  const parts = sessionKey.split(":");
  if (parts.length < 3 || parts[0] !== "agent") {
    return undefined;
  }
  const platform = parts[2];
  if (!platform || platform === "main") {
    return undefined;
  }
  return {
    platform,
    peerKind: parts[3],
    peerId: parts[4],
  };
}

/**
 * Scan working-context files for YAML frontmatter `slack_channel_id` and build
 * a map from lowercase channel ID → filename (without extension).
 */
function buildChannelIdMap(contextDir: string): Map<string, string> {
  const map = new Map<string, string>();
  let files: string[];
  try {
    files = fs.readdirSync(contextDir).filter((f) => f.endsWith(".md"));
  } catch {
    return map;
  }
  for (const file of files) {
    try {
      const content = fs.readFileSync(path.join(contextDir, file), "utf-8");
      // Parse YAML frontmatter between --- delimiters
      const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
      if (!fmMatch) {
        continue;
      }
      const slackIdMatch = fmMatch[1].match(/^slack_channel_id:\s*(.+)$/m);
      if (slackIdMatch) {
        const channelId = slackIdMatch[1].trim().toLowerCase();
        const name = file.replace(/\.md$/, "");
        map.set(channelId, name);
      }
    } catch {
      // Skip unreadable files
    }
  }
  return map;
}

function extractBootQueries(content: string): string[] {
  const bootSection = content.match(/## Boot Queries\s*\n([\s\S]*?)(?=\n## |\n---|Z|$)/);
  if (!bootSection) {
    return [];
  }
  const lines = bootSection[1].split("\n");
  const commands: string[] = [];
  for (const line of lines) {
    const trimmed = line.trim();
    // Match lines containing memory-structured.py commands (in code blocks or bare)
    const match = trimmed.match(/`?(python3?\s+.*memory-structured\.py\s+.+?)`?$/);
    if (match) {
      // Strip backticks
      commands.push(match[1] ?? match[0].replace(/`/g, ""));
    }
  }
  return commands;
}

function extractRequiredDocs(content: string): string[] {
  const docsSection = content.match(/## Required Docs\s*\n([\s\S]*?)(?=\n## |\n---|Z|$)/);
  if (!docsSection) {
    return [];
  }
  const lines = docsSection[1].split("\n");
  const paths: string[] = [];
  for (const line of lines) {
    const trimmed = line.trim().replace(/^[-*]\s*/, "");
    if (trimmed && !trimmed.startsWith("#")) {
      paths.push(trimmed);
    }
  }
  return paths;
}

function runQuery(command: string): string | null {
  try {
    return execSync(command, {
      timeout: EXEC_TIMEOUT_MS,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (err) {
    console.warn(`[context-loader] Query failed: ${command} — ${String(err)}`);
    return null;
  }
}

function readDoc(docPath: string): string | null {
  // Resolve relative to Obsidian vault, or use absolute path
  const resolved = path.isAbsolute(docPath) ? docPath : path.join(OBSIDIAN_VAULT, docPath);
  try {
    let content = fs.readFileSync(resolved, "utf-8");
    if (content.length > DOC_MAX_CHARS) {
      content = content.slice(0, DOC_MAX_CHARS) + "\n\n[...truncated]";
    }
    return content;
  } catch (err) {
    console.warn(`[context-loader] Failed to read doc: ${resolved} — ${String(err)}`);
    return null;
  }
}

const contextLoaderHook: HookHandler = async (event) => {
  if (!isAgentBootstrapEvent(event)) {
    return;
  }

  const context = event.context;

  // Skip subagent sessions
  if (context.sessionKey && isSubagentSessionKey(context.sessionKey)) {
    return;
  }

  const cfg = context.cfg;
  const hookConfig = resolveHookConfig(cfg, HOOK_KEY);
  if (!hookConfig || hookConfig.enabled === false) {
    return;
  }

  const workspaceDir = context.workspaceDir;
  if (!workspaceDir) {
    return;
  }

  // Determine channel from session key
  const contextDir = path.join(workspaceDir, "memory", "working-context");
  let resolvedChannel: string | undefined;

  if (context.sessionKey) {
    const info = parseSessionKeyInfo(context.sessionKey);
    if (info) {
      // If we have a peer ID (e.g. Slack channel ID), resolve via frontmatter mapping
      if (info.peerId) {
        const channelMap = buildChannelIdMap(contextDir);
        resolvedChannel = channelMap.get(info.peerId.toLowerCase());
      }
      // Fall back to platform name if no peer-based match
      if (!resolvedChannel) {
        resolvedChannel = info.platform;
      }
    }
  }

  // Try resolved channel file first, then platform file, then default
  const candidates = resolvedChannel
    ? [path.join(contextDir, `${resolvedChannel}.md`), path.join(contextDir, "default.md")]
    : [path.join(contextDir, "default.md")];

  let contextFilePath: string | undefined;
  let contextContent: string | undefined;
  for (const candidate of candidates) {
    try {
      contextContent = fs.readFileSync(candidate, "utf-8");
      contextFilePath = candidate;
      break;
    } catch {
      // Try next candidate
    }
  }

  if (!contextContent) {
    return;
  }

  const sections: string[] = [];
  sections.push(contextContent);

  // Execute boot queries
  const queries = extractBootQueries(contextContent);
  if (queries.length > 0) {
    const queryResults: string[] = [];
    for (const query of queries) {
      const result = runQuery(query);
      if (result) {
        queryResults.push(result);
      }
    }
    if (queryResults.length > 0) {
      sections.push("\n## Structured Memory Query Results\n");
      sections.push(queryResults.join("\n\n---\n\n"));
    }
  }

  // Read required docs
  const docPaths = extractRequiredDocs(contextContent);
  if (docPaths.length > 0) {
    const docSections: string[] = [];
    for (const docPath of docPaths) {
      const content = readDoc(docPath);
      if (content) {
        const basename = path.basename(docPath);
        docSections.push(`### ${basename}\n\n${content}`);
      }
    }
    if (docSections.length > 0) {
      sections.push("\n## Reference Documents\n");
      sections.push(docSections.join("\n\n"));
    }
  }

  const combined = sections.join("\n");
  const label = contextFilePath ? path.basename(contextFilePath) : "CONTEXT.md";

  context.bootstrapFiles = [
    ...context.bootstrapFiles,
    {
      name: "CONTEXT.md" as WorkspaceBootstrapFileName,
      path: label,
      content: combined,
      missing: false,
    },
  ];
};

export default contextLoaderHook;

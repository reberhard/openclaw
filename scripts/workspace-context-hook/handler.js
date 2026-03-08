import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { t as resolveHookConfig } from "../../config-BeIwBEE4.js";
import { b as isSubagentSessionKey } from "../../session-key-CPPWn8gW.js";
import { ft as isAgentBootstrapEvent } from "../../subsystem-CGE2Gr4r.js";

//#region src/hooks/bundled/context-loader/handler.ts
const HOOK_KEY = "context-loader";
const EXEC_TIMEOUT_MS = 5000;
const DOC_MAX_CHARS = 5000;
const OBSIDIAN_VAULT = path.join(process.env.HOME ?? "/Users/eberhard", "Obsidian-Vault");

function parseSessionKeyInfo(sessionKey) {
  const parts = sessionKey.split(":");
  if (parts.length < 3 || parts[0] !== "agent") {
    return undefined;
  }
  const platform = parts[2];
  if (!platform || platform === "main") {
    return undefined;
  }
  const info = { platform, peerKind: parts[3], peerId: parts[4] };
  const threadIdx = parts.indexOf("thread");
  if (threadIdx !== -1 && parts[threadIdx + 1]) {
    info.threadTs = parts[threadIdx + 1];
  }
  return info;
}

function buildPositionHeader(info, channelName) {
  const channel = channelName ? `#${channelName}` : (info.peerId ?? info.platform);
  if (info.threadTs) {
    return `> POSITION: Thread in ${channel} (thread_ts: ${info.threadTs})\n> To post NEW top-level messages in the channel, use message send WITHOUT thread_ts.\n`;
  }
  return `> POSITION: Main channel ${channel}\n`;
}

function buildChannelIdMap(contextDir) {
  const map = new Map();
  const nameMap = new Map(); // channel_name → filename (fallback)
  let files;
  try {
    files = fs.readdirSync(contextDir).filter((f) => f.endsWith(".md"));
  } catch {
    return map;
  }
  for (const file of files) {
    try {
      const content = fs.readFileSync(path.join(contextDir, file), "utf-8");
      const name = file.replace(/\.md$/, "");
      // Always register filename as a potential match
      nameMap.set(name.toLowerCase(), name);
      const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
      if (!fmMatch) {
        continue;
      }
      const slackIdMatch = fmMatch[1].match(/^slack_channel_id:\s*(.+)$/m);
      if (slackIdMatch) {
        const channelId = slackIdMatch[1].trim().toLowerCase();
        map.set(channelId, name);
      }
      // Also index by channel_name frontmatter field
      const channelNameMatch = fmMatch[1].match(/^channel_name:\s*(.+)$/m);
      if (channelNameMatch) {
        nameMap.set(channelNameMatch[1].trim().toLowerCase(), name);
      }
    } catch {
      /* skip */
    }
  }
  // Attach nameMap for fallback resolution
  map._nameMap = nameMap;
  return map;
}

function extractBootQueries(content) {
  const bootSection = content.match(/## Boot Queries\s*\n([\s\S]*?)(?=\n## |\n---|$)/);
  if (!bootSection) {
    return [];
  }
  const lines = bootSection[1].split("\n");
  const commands = [];
  for (const line of lines) {
    const trimmed = line.trim();
    const match = trimmed.match(/`?(python3?\s+.*memory-structured\.py\s+.+?)`?$/);
    if (match) {
      commands.push(match[1] ?? match[0].replace(/`/g, ""));
    }
  }
  return commands;
}

function extractRequiredDocs(content) {
  const docsSection = content.match(/## Required Docs\s*\n([\s\S]*?)(?=\n## |\n---|$)/);
  if (!docsSection) {
    return [];
  }
  const lines = docsSection[1].split("\n");
  const paths = [];
  for (const line of lines) {
    const trimmed = line.trim().replace(/^[-*]\s*/, "");
    if (trimmed && !trimmed.startsWith("#")) {
      paths.push(trimmed);
    }
  }
  return paths;
}

function runQuery(command) {
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

function readDoc(docPath) {
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

const contextLoaderHook = async (event) => {
  if (!isAgentBootstrapEvent(event)) {
    return;
  }
  const context = event.context;
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

  const contextDir = path.join(workspaceDir, "memory", "working-context");
  let resolvedChannel;
  let sessionInfo;

  if (context.sessionKey) {
    sessionInfo = parseSessionKeyInfo(context.sessionKey);
    if (sessionInfo) {
      if (sessionInfo.peerId) {
        const channelMap = buildChannelIdMap(contextDir);
        resolvedChannel = channelMap.get(sessionInfo.peerId.toLowerCase());
        // Fallback: try matching channel name from session context against nameMap
        if (!resolvedChannel && channelMap._nameMap) {
          const channelName = context.channelName || context.channel?.name;
          if (channelName) {
            resolvedChannel = channelMap._nameMap.get(channelName.toLowerCase());
          }
        }
      }
      // Only fall back to platform name if we have no channel match at all
      // (platform is "slack"/"whatsapp"/etc — not useful as a filename)
      if (!resolvedChannel) {
        // Last resort: check if there's a file named after the platform
        const platformFile = path.join(contextDir, `${sessionInfo.platform}.md`);
        try {
          fs.accessSync(platformFile);
          resolvedChannel = sessionInfo.platform;
        } catch {
          /* no platform file */
        }
      }
    }
  }

  const candidates = resolvedChannel
    ? [path.join(contextDir, `${resolvedChannel}.md`), path.join(contextDir, "default.md")]
    : [path.join(contextDir, "default.md")];

  let contextFilePath;
  let contextContent;
  for (const candidate of candidates) {
    try {
      contextContent = fs.readFileSync(candidate, "utf-8");
      contextFilePath = candidate;
      break;
    } catch {
      /* try next */
    }
  }
  if (!contextContent) {
    return;
  }

  const sections = [];
  if (sessionInfo) {
    sections.push(buildPositionHeader(sessionInfo, resolvedChannel));
  }
  sections.push(contextContent);

  const queries = extractBootQueries(contextContent);
  if (queries.length > 0) {
    const queryResults = [];
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

  const docPaths = extractRequiredDocs(contextContent);
  if (docPaths.length > 0) {
    const docSections = [];
    for (const dp of docPaths) {
      const content = readDoc(dp);
      if (content) {
        docSections.push(`### ${path.basename(dp)}\n\n${content}`);
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
    { name: "CONTEXT.md", path: label, content: combined, missing: false },
  ];
};

//#endregion
export { contextLoaderHook as default };

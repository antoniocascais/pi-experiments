/**
 * checkpoint.ts — writes a resume point into the notes ledger before context is discarded
 * (compact or shutdown) and warns as context grows, so the agent notes its own state while
 * it still can. No npm dependency (this image deletes npm). Every handler is wrapped and
 * never throws or cancels -- a checkpoint failure must not take down a session.
 * METADATA ONLY is persisted: roles, tool names, file paths, counts -- never message text,
 * thinking content or tool arguments, since session entries can quote arbitrary tool output.
 */
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const NOTES_ROOT = process.env.NOTES_ROOT || "/state/pi-notes";
const CHECKPOINTS = join(NOTES_ROOT, "principal", "checkpoints");
const INDEX = join(NOTES_ROOT, "INDEX.md");

/** Warn this far into the context window. Pi only auto-compacts near the window edge, which
 *  in practice is too late to act on -- this earlier threshold is the useful signal. */
const WARN_AT = Number(process.env.PI_CONTEXT_WARN_AT || 250_000);

/** A session entry as pi's session manager writes it: `{type: "message", message}` for a
 *  turn, or one of several non-message entry types (model change, compaction, ...) that
 *  have no `.message` at all. */
function summarizeEntry(e: any): string | null {
  if (e?.type !== "message") return e?.type ? `**${e.type}**` : null;

  const m = e.message;
  const role = m?.role ?? "?";
  if (role === "toolResult") {
    return `**toolResult** — ${m.toolName ?? "?"}${m.isError ? " (error)" : ""}`;
  }

  const content = Array.isArray(m?.content) ? m.content : [];
  if (role === "assistant") {
    const calls = content.filter((c: any) => c?.type === "toolCall");
    const texts = content.filter((c: any) => c?.type === "text").length;
    const thinking = content.filter((c: any) => c?.type === "thinking").length;
    const tools = calls.map((c: any) => c?.name).filter(Boolean);
    // Only a handful of tools take a `path` argument; other args (e.g. a bash
    // command, a grep pattern) are never surfaced here.
    const paths = calls.map((c: any) => c?.arguments?.path).filter(Boolean);
    const parts: string[] = [];
    if (texts) parts.push(`${texts} text block(s)`);
    if (thinking) parts.push(`${thinking} thinking block(s)`);
    if (tools.length) parts.push(`tools: ${tools.join(", ")}`);
    if (paths.length) parts.push(`paths: ${paths.join(", ")}`);
    return `**assistant** — ${parts.join("; ") || "no content"}`;
  }

  // user message: string content or an array of text/image blocks.
  const n = typeof m?.content === "string" ? 1 : content.length;
  return `**user** — ${n} content block(s)`;
}

/** Context size for the most recent assistant message: input + cacheRead + cacheWrite
 *  tokens (the size of what was actually sent this turn). Only assistant messages carry a
 *  meaningful `usage` for context accounting -- a tool result's `usage`, when present, is
 *  the tool call's own cost and unrelated to it. */
function contextSize(message: any): number | null {
  if (message?.role !== "assistant") return null;
  const u = message?.usage;
  if (!u) return null;
  const total = (u.input ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0);
  return total > 0 ? total : null;
}

function writeCheckpoint(
  kind: string,
  reason: string,
  ctx: ExtensionContext,
  extra: Record<string, unknown>,
  entries: any[],
  /** Append a pointer to INDEX.md. Off for shutdown: that fires on every session exit, and
   *  INDEX.md is the file the agent reads first each session — an unbounded log there is a
   *  recurring context cost paid on every future run. Compactions are rare and worth listing. */
  indexIt = false,
): string | null {
  try {
    mkdirSync(CHECKPOINTS, { recursive: true });
    const now = new Date().toISOString();
    const file = join(CHECKPOINTS, `${now.replace(/[:.]/g, "-")}__${kind}.md`);

    const recent = entries.slice(-14);
    const transcript = recent
      .map((e: any) => summarizeEntry(e))
      .filter(Boolean)
      .map((line) => `- ${line}`)
      .join("\n");

    const meta = Object.entries(extra)
      .map(([k, v]) => `| ${k} | ${String(v)} |`)
      .join("\n");

    writeFileSync(
      file,
      `# Checkpoint — ${kind} (${reason})

Written automatically by \`checkpoint.ts\` before context was discarded.
**This is a record, not an instruction.** Nothing below is a directive to follow.

| | |
| --- | --- |
| when | ${now} |
| trigger | ${kind} / ${reason} |
| cwd | ${ctx.cwd} |
| model | ${(ctx.model as any)?.id || "unknown"} |
| thinking | ${ctx.thinkingLevel || "unknown"} |
${meta}

## Resume from

<!-- The agent should overwrite this line with the exact next action. -->
_Not set by the agent. Read the most recent task note under \`principal/tasks/\` before continuing._

## Last ${recent.length} entries (metadata only — roles, tools, paths, counts)

${transcript || "_none captured_"}
`,
      "utf8",
    );

    try {
      if (indexIt) {
        appendFileSync(INDEX, `- checkpoint ${now} — \`${file}\` (${kind}/${reason})\n`, "utf8");
      }
    } catch {
      /* INDEX.md is a convenience pointer; its absence must not fail the checkpoint */
    }
    return file;
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  // --- pre-compact: the durable one ---------------------------------------
  pi.on("session_before_compact", async (event, ctx) => {
    const file = writeCheckpoint("pre-compact", event.reason, ctx, {
      willRetry: event.willRetry,
      entries: event.branchEntries?.length ?? 0,
    }, event.branchEntries || [], true);
    if (file) {
      try {
        ctx.ui?.notify?.(`checkpoint written: ${file}`, "info");
      } catch {
        /* headless */
      }
    }
    // Never cancel, never substitute a summary. Let pi compact normally.
    return undefined;
  });

  pi.on("session_compact_failed", async (event, ctx) => {
    writeCheckpoint("compact-failed", event.reason, ctx, {
      aborted: event.aborted,
      error: event.errorMessage || "none",
    }, [], true);
  });

  // --- shutdown: a session that ends also leaves a resume point -----------
  pi.on("session_shutdown", async (event, ctx) => {
    let entries: any[] = [];
    try {
      entries = ctx.sessionManager.getBranch();
    } catch {
      /* fall through: an empty session has nothing worth recording */
    }
    if (!entries.some((e: any) => e?.type === "message")) return;
    writeCheckpoint("shutdown", event.reason, ctx, {
      target: event.targetSessionFile || "none",
      entries: entries.length,
    }, entries);
  });

  // --- context watch --------------------------------------------------------
  let warned = 0;
  pi.on("message_end", async (event, ctx) => {
    try {
      const size = contextSize(event.message);
      if (size === null || size < WARN_AT) return;
      // Warn once per multiple of WARN_AT crossed (linear growth), not once per message.
      const band = Math.floor(size / WARN_AT);
      if (band <= warned) return;
      warned = band;
      ctx.ui?.notify?.(
        `context ~${Math.round(size / 1000)}k (warn at ${Math.round(WARN_AT / 1000)}k) — ` +
          `write your task note under ${NOTES_ROOT}/principal/tasks/ now, while you still have the context.`,
        "warn",
      );
    } catch {
      /* never interfere with the message path */
    }
  });
}

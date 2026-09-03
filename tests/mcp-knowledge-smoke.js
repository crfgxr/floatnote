#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "floatnote-knowledge-test-"));
const workspaceId = "11111111-1111-4111-8111-111111111111";
const devId = "22222222-2222-4222-8222-222222222222";
const marketingId = "33333333-3333-4333-8333-333333333333";

fs.writeFileSync(path.join(tempHome, ".floatnote-folders.json"), JSON.stringify([
  { id: workspaceId, name: "FloatNote", isExpanded: true, localPath: "/tmp/floatnote" },
]));
fs.writeFileSync(path.join(tempHome, ".floatnote-tabs.json"), JSON.stringify([
  { id: devId, title: "Development", html: "<p>Build topic context retrieval.</p>", folderId: workspaceId },
  { id: marketingId, title: "Marketing", html: "<p>Explain the token-saving knowledge workflow.</p>", folderId: workspaceId },
]));

const child = spawn(process.execPath, [path.join(__dirname, "..", "mcp-server.js")], {
  env: { ...process.env, HOME: tempHome },
  stdio: ["pipe", "pipe", "pipe"],
});

let nextId = 1;
let stdout = "";
const pending = new Map();

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  stdout += chunk;
  let newline;
  while ((newline = stdout.indexOf("\n")) >= 0) {
    const line = stdout.slice(0, newline).trim();
    stdout = stdout.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  }
});

function send(method, params = {}) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${method}`));
    }, 5000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    });
  });
}

function notify(method, params = {}) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

function toolText(result) {
  return result.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
}

(async () => {
  try {
    await send("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "floatnote-smoke-test", version: "1.0.0" },
    });
    notify("notifications/initialized");

    const listed = await send("tools/list");
    const names = new Set(listed.tools.map((tool) => tool.name));
    for (const name of ["list_workspaces", "list_topics", "connect_topics", "get_topic_context", "save_workspace_memory", "list_workspace_memory", "forget_workspace_memory"]) {
      assert(names.has(name), `missing tool ${name}`);
    }

    await send("tools/call", {
      name: "connect_topics",
      arguments: { source: devId, target: marketingId },
    });
    const connectedTabs = JSON.parse(fs.readFileSync(path.join(tempHome, ".floatnote-tabs.json"), "utf8"));
    assert.deepEqual(connectedTabs[0].linkedTopicIds, [marketingId]);

    const saved = await send("tools/call", {
      name: "save_workspace_memory",
      arguments: {
        workspace: "FloatNote",
        topic: "Development",
        relatedTopics: ["Marketing"],
        type: "decision",
        content: "Use Workspace to Topics terminology.",
        sourceSession: "smoke-session",
      },
    });
    assert.match(toolText(saved), /Memory checkpoint saved/);

    const context = await send("tools/call", {
      name: "get_topic_context",
      arguments: { identifier: "Development", query: "token workflow", maxChars: 2500 },
    });
    const text = toolText(context);
    assert(text.length <= 2500, `context exceeded budget: ${text.length}`);
    assert.match(text, /Active topic · Development/);
    assert.match(text, /Connected topic · Marketing/);
    assert.match(text, /Use Workspace to Topics terminology/);

    console.log("FloatNote knowledge MCP smoke test passed.");
  } finally {
    child.kill();
    fs.rmSync(tempHome, { recursive: true, force: true });
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

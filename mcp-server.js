#!/usr/bin/env node

const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");
const fs = require("fs");
const path = require("path");
const os = require("os");

const TABS_PATH = path.join(os.homedir(), ".floatnote-tabs.json");

// --- Helpers ---

function readTabs() {
  try {
    const data = fs.readFileSync(TABS_PATH, "utf8");
    return JSON.parse(data);
  } catch {
    return [];
  }
}

function writeTabs(tabs) {
  fs.writeFileSync(TABS_PATH, JSON.stringify(tabs), "utf8");
}

function stripHTML(html) {
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n")
    .replace(/<\/div>/gi, "\n")
    .replace(/<\/li>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// --- MCP Server ---

const server = new McpServer({
  name: "floatnote",
  version: "1.1.0",
});

/*
  Tab JSON schema (stored in ~/.floatnote-tabs.json as an array):
  {
    "id": "UUID string",
    "title": "Tab display name",
    "html": "Note content as HTML string",
    "recordingPath": "Path to .m4a file (optional, null for regular notes)"
  }
*/

// --- Tools ---

server.tool("list_notes", "List all FloatNote tabs with their IDs and titles. Each tab has: id (UUID), title, html (content), recordingPath (optional .m4a path for audio recordings).", {}, async () => {
  const tabs = readTabs();
  if (tabs.length === 0) {
    return { content: [{ type: "text", text: "No notes found." }] };
  }
  const list = tabs.map((t, i) => `${i + 1}. [${t.id}] ${t.title}`).join("\n");
  return { content: [{ type: "text", text: list }] };
});

server.tool(
  "read_note",
  "Read the content of a FloatNote tab by ID or title. Returns plain text content.",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
  },
  async ({ identifier }) => {
    const tabs = readTabs();
    const tab =
      tabs.find((t) => t.id === identifier) ||
      tabs.find((t) => t.title.toLowerCase() === identifier.toLowerCase()) ||
      tabs.find((t) => t.title.toLowerCase().includes(identifier.toLowerCase()));

    if (!tab) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    const text = stripHTML(tab.html);
    return {
      content: [
        {
          type: "text",
          text: `# ${tab.title}\nID: ${tab.id}\n\n${text || "(empty note)"}`,
        },
      ],
    };
  }
);

server.tool(
  "read_note_html",
  "Read the raw HTML content of a FloatNote tab by ID or title",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
  },
  async ({ identifier }) => {
    const tabs = readTabs();
    const tab =
      tabs.find((t) => t.id === identifier) ||
      tabs.find((t) => t.title.toLowerCase() === identifier.toLowerCase()) ||
      tabs.find((t) => t.title.toLowerCase().includes(identifier.toLowerCase()));

    if (!tab) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    return {
      content: [
        {
          type: "text",
          text: `# ${tab.title} (HTML)\nID: ${tab.id}\n\n${tab.html || "(empty)"}`,
        },
      ],
    };
  }
);

server.tool(
  "edit_note",
  "Replace the HTML content of an existing FloatNote tab. The app auto-detects changes to ~/.floatnote-tabs.json.",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
    html: z.string().describe("New HTML content for the note"),
  },
  async ({ identifier, html }) => {
    const tabs = readTabs();
    const idx = tabs.findIndex(
      (t) =>
        t.id === identifier ||
        t.title.toLowerCase() === identifier.toLowerCase() ||
        t.title.toLowerCase().includes(identifier.toLowerCase())
    );

    if (idx === -1) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    tabs[idx].html = html;
    writeTabs(tabs);

    return {
      content: [
        {
          type: "text",
          text: `Updated note "${tabs[idx].title}" (${tabs[idx].id}). Restart or switch tabs in FloatNote to see changes.`,
        },
      ],
    };
  }
);

server.tool(
  "append_to_note",
  "Append text or HTML to an existing FloatNote tab",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
    content: z.string().describe("HTML content to append"),
  },
  async ({ identifier, content }) => {
    const tabs = readTabs();
    const idx = tabs.findIndex(
      (t) =>
        t.id === identifier ||
        t.title.toLowerCase() === identifier.toLowerCase() ||
        t.title.toLowerCase().includes(identifier.toLowerCase())
    );

    if (idx === -1) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    // Append with a line break
    tabs[idx].html = (tabs[idx].html || "") + "<br>" + content;
    writeTabs(tabs);

    return {
      content: [
        {
          type: "text",
          text: `Appended to "${tabs[idx].title}". Switch tabs in FloatNote to see changes.`,
        },
      ],
    };
  }
);

server.tool(
  "create_note",
  "Create a new FloatNote tab with a title and optional HTML content. JSON schema per tab: {id: UUID, title: string, html: string, recordingPath: string|null}. The app auto-detects new tabs written to ~/.floatnote-tabs.json.",
  {
    title: z.string().describe("Title for the new note tab"),
    html: z.string().optional().describe("Initial HTML content (optional)"),
  },
  async ({ title, html }) => {
    const tabs = readTabs();
    const crypto = require("crypto");
    const id = crypto.randomUUID();
    tabs.push({ id, title, html: html || "", recordingPath: null });
    writeTabs(tabs);

    return {
      content: [
        {
          type: "text",
          text: `Created note "${title}" (${id}). Restart FloatNote to see the new tab.`,
        },
      ],
    };
  }
);

server.tool(
  "delete_note",
  "Delete a FloatNote tab by ID or title",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
  },
  async ({ identifier }) => {
    const tabs = readTabs();
    const idx = tabs.findIndex(
      (t) =>
        t.id === identifier ||
        t.title.toLowerCase() === identifier.toLowerCase() ||
        t.title.toLowerCase().includes(identifier.toLowerCase())
    );

    if (idx === -1) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    const removed = tabs.splice(idx, 1)[0];
    writeTabs(tabs);

    return {
      content: [
        {
          type: "text",
          text: `Deleted note "${removed.title}" (${removed.id}). Restart FloatNote to see changes.`,
        },
      ],
    };
  }
);

server.tool(
  "search_notes",
  "Search across all FloatNote tabs for text content",
  {
    query: z.string().describe("Text to search for (case-insensitive)"),
  },
  async ({ query }) => {
    const tabs = readTabs();
    const q = query.toLowerCase();
    const matches = tabs.filter((t) => {
      const text = stripHTML(t.html).toLowerCase();
      return text.includes(q) || t.title.toLowerCase().includes(q);
    });

    if (matches.length === 0) {
      return { content: [{ type: "text", text: `No notes matching "${query}".` }] };
    }

    const results = matches
      .map((t) => {
        const text = stripHTML(t.html);
        const idx = text.toLowerCase().indexOf(q);
        const snippet = idx >= 0 ? "..." + text.substring(Math.max(0, idx - 40), idx + query.length + 40) + "..." : "";
        return `[${t.id}] ${t.title}\n  ${snippet}`;
      })
      .join("\n\n");

    return { content: [{ type: "text", text: `Found ${matches.length} note(s):\n\n${results}` }] };
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);

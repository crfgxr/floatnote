#!/usr/bin/env node

const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");
const fs = require("fs");
const path = require("path");
const os = require("os");

const TABS_PATH = path.join(os.homedir(), ".floatnote-tabs.json");
const FOLDERS_PATH = path.join(os.homedir(), ".floatnote-folders.json");

// --- Helpers ---

function readJSON(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return [];
  }
}

function writeJSON(p, value) {
  const tmp = p + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(value), "utf8");
  fs.renameSync(tmp, p);
}

function readTabs() { return readJSON(TABS_PATH); }
function writeTabs(tabs) { writeJSON(TABS_PATH, tabs); }
function readFolders() { return readJSON(FOLDERS_PATH); }
function writeFolders(folders) { writeJSON(FOLDERS_PATH, folders); }

function findFolder(folders, identifier) {
  return (
    folders.find((f) => f.id === identifier) ||
    folders.find((f) => f.name.toLowerCase() === identifier.toLowerCase()) ||
    folders.find((f) => f.name.toLowerCase().includes(identifier.toLowerCase()))
  );
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

const MCP_VERSION = "1.3.0";

// Sentinel folder ID for loose-trashed notes (notes moved to Trash by themselves).
// Mirrors `TRASH_FOLDER_ID` in App.swift — must stay in sync.
const TRASH_FOLDER_ID = "00000000-0000-0000-0000-000000000001";

const server = new McpServer({
  name: "floatnote",
  version: MCP_VERSION,
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
    return { content: [{ type: "text", text: `FloatNote MCP v${MCP_VERSION} — No notes found.` }] };
  }
  const list = tabs.map((t, i) => `${i + 1}. [${t.id}] ${t.title}`).join("\n");
  return { content: [{ type: "text", text: `FloatNote MCP v${MCP_VERSION}\n\n${list}` }] };
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
  "Move a FloatNote tab to the Trash. Reversible via restore_note. Pass permanent=true to skip the Trash and hard-delete (no restore).",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
    permanent: z.boolean().optional().describe("If true, hard-delete instead of moving to Trash"),
  },
  async ({ identifier, permanent }) => {
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

    if (permanent) {
      const removed = tabs.splice(idx, 1)[0];
      writeTabs(tabs);
      return {
        content: [{ type: "text", text: `Permanently deleted note "${removed.title}" (${removed.id}).` }],
      };
    }

    tabs[idx].folderId = TRASH_FOLDER_ID;
    writeTabs(tabs);
    return {
      content: [
        {
          type: "text",
          text: `Moved note "${tabs[idx].title}" to Trash. Use restore_note to bring it back.`,
        },
      ],
    };
  }
);

server.tool(
  "restore_note",
  "Restore a trashed FloatNote tab. Loose-trashed notes return to the root.",
  {
    identifier: z.string().describe("Tab ID (UUID) or title"),
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
    if (tab.folderId !== TRASH_FOLDER_ID) {
      return { content: [{ type: "text", text: `Note "${tab.title}" is not in the Trash.` }] };
    }
    tab.folderId = null;
    writeTabs(tabs);
    return { content: [{ type: "text", text: `Restored "${tab.title}" to root.` }] };
  }
);

server.tool(
  "restore_folder",
  "Restore a trashed folder (and the notes still inside it) back to the sidebar.",
  {
    identifier: z.string().describe("Folder ID (UUID) or name"),
  },
  async ({ identifier }) => {
    const folders = readFolders();
    const folder = findFolder(folders, identifier);
    if (!folder) {
      return { content: [{ type: "text", text: `Folder not found: "${identifier}"` }] };
    }
    if (!folder.isTrashed) {
      return { content: [{ type: "text", text: `Folder "${folder.name}" is not in the Trash.` }] };
    }
    folder.isTrashed = false;
    writeFolders(folders);
    return { content: [{ type: "text", text: `Restored folder "${folder.name}".` }] };
  }
);

server.tool(
  "empty_trash",
  "Permanently delete every trashed folder, every note inside trashed folders, and every loose-trashed note. Cannot be undone.",
  {},
  async () => {
    const folders = readFolders();
    const tabs = readTabs();
    const trashedFolderIds = new Set(folders.filter((f) => f.isTrashed).map((f) => f.id));

    const keptTabs = tabs.filter(
      (t) => t.folderId !== TRASH_FOLDER_ID && !trashedFolderIds.has(t.folderId)
    );
    const removedTabCount = tabs.length - keptTabs.length;

    const keptFolders = folders.filter((f) => !f.isTrashed);
    const removedFolderCount = folders.length - keptFolders.length;

    if (removedTabCount === 0 && removedFolderCount === 0) {
      return { content: [{ type: "text", text: "Trash is already empty." }] };
    }

    writeTabs(keptTabs);
    writeFolders(keptFolders);
    return {
      content: [
        {
          type: "text",
          text: `Emptied Trash: removed ${removedFolderCount} folder(s) and ${removedTabCount} note(s).`,
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

server.tool(
  "list_folders",
  "List all FloatNote folders. Each folder: {id (UUID), name, isExpanded}. Notes reference folders via folderId; folderId=null means the note lives at the root.",
  {},
  async () => {
    const folders = readFolders();
    const tabs = readTabs();
    if (folders.length === 0) {
      return { content: [{ type: "text", text: `FloatNote MCP v${MCP_VERSION} — No folders.` }] };
    }
    const lines = folders.map((f) => {
      const count = tabs.filter((t) => t.folderId === f.id).length;
      return `[${f.id}] ${f.name} (${count} note${count === 1 ? "" : "s"})`;
    }).join("\n");
    return { content: [{ type: "text", text: `FloatNote MCP v${MCP_VERSION}\n\n${lines}` }] };
  }
);

server.tool(
  "create_folder",
  "Create a new folder in FloatNote's sidebar. Returns the folder's UUID. Notes can later be moved into it via move_note_to_folder.",
  {
    name: z.string().describe("Folder display name"),
  },
  async ({ name }) => {
    const folders = readFolders();
    if (folders.some((f) => f.name.toLowerCase() === name.toLowerCase())) {
      return { content: [{ type: "text", text: `A folder named "${name}" already exists.` }] };
    }
    const crypto = require("crypto");
    const id = crypto.randomUUID();
    folders.push({ id, name, isExpanded: true });
    writeFolders(folders);
    return {
      content: [
        {
          type: "text",
          text: `Created folder "${name}" (${id}). Restart FloatNote to see it.`,
        },
      ],
    };
  }
);

server.tool(
  "rename_folder",
  "Rename an existing folder by ID or current name.",
  {
    identifier: z.string().describe("Folder ID (UUID) or current name"),
    name: z.string().describe("New folder name"),
  },
  async ({ identifier, name }) => {
    const folders = readFolders();
    const folder = findFolder(folders, identifier);
    if (!folder) {
      return { content: [{ type: "text", text: `Folder not found: "${identifier}"` }] };
    }
    folder.name = name;
    writeFolders(folders);
    return { content: [{ type: "text", text: `Renamed folder to "${name}" (${folder.id}).` }] };
  }
);

server.tool(
  "delete_folder",
  "Move a folder (and its notes) to the Trash. Reversible via restore_folder. Pass permanent=true to hard-delete the folder AND every note inside it.",
  {
    identifier: z.string().describe("Folder ID (UUID) or name"),
    permanent: z.boolean().optional().describe("If true, hard-delete the folder and all its notes"),
  },
  async ({ identifier, permanent }) => {
    const folders = readFolders();
    const folder = findFolder(folders, identifier);
    if (!folder) {
      return { content: [{ type: "text", text: `Folder not found: "${identifier}"` }] };
    }

    if (permanent) {
      const tabs = readTabs();
      const removedCount = tabs.filter((t) => t.folderId === folder.id).length;
      const keptTabs = tabs.filter((t) => t.folderId !== folder.id);
      writeTabs(keptTabs);
      const remaining = folders.filter((f) => f.id !== folder.id);
      writeFolders(remaining);
      return {
        content: [
          {
            type: "text",
            text: `Permanently deleted folder "${folder.name}" and ${removedCount} note(s).`,
          },
        ],
      };
    }

    folder.isTrashed = true;
    writeFolders(folders);
    const inFolder = readTabs().filter((t) => t.folderId === folder.id).length;
    return {
      content: [
        {
          type: "text",
          text: `Moved folder "${folder.name}" (${inFolder} note(s)) to Trash. Use restore_folder to bring it back.`,
        },
      ],
    };
  }
);

server.tool(
  "move_note_to_folder",
  "Move a note into a folder, or pass folder=null/empty to move it back to the root.",
  {
    note: z.string().describe("Note ID (UUID) or title"),
    folder: z.string().nullable().optional().describe("Folder ID (UUID), folder name, or null/empty for root"),
  },
  async ({ note, folder }) => {
    const tabs = readTabs();
    const tab =
      tabs.find((t) => t.id === note) ||
      tabs.find((t) => t.title.toLowerCase() === note.toLowerCase()) ||
      tabs.find((t) => t.title.toLowerCase().includes(note.toLowerCase()));
    if (!tab) {
      return { content: [{ type: "text", text: `Note not found: "${note}"` }] };
    }

    let targetId = null;
    let targetName = "root";
    if (folder && folder.length > 0) {
      const folders = readFolders();
      const f = findFolder(folders, folder);
      if (!f) {
        return { content: [{ type: "text", text: `Folder not found: "${folder}"` }] };
      }
      targetId = f.id;
      targetName = f.name;
    }

    tab.folderId = targetId;
    writeTabs(tabs);
    return {
      content: [
        {
          type: "text",
          text: `Moved "${tab.title}" to ${targetName}.`,
        },
      ],
    };
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);

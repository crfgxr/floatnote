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
  // Unique temp name avoids collisions with a concurrent write or a stale
  // leftover .tmp from a previous crash. Atomic rename into place.
  const tmp = `${p}.${process.pid}.${Date.now()}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(value), "utf8");
    fs.renameSync(tmp, p);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    throw e;
  }
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

// --- Excalidraw boards ---
//
// Every note has an attached Excalidraw whiteboard stored at
// ~/.floatnote-excalidraw/<noteUUID>.excalidraw.json ({elements, appState, files}).
// The app normalizes scenes through Excalidraw's restore() on load, so elements
// written here need correct structure/geometry but not every internal field.

const EXCALIDRAW_DIR = path.join(os.homedir(), ".floatnote-excalidraw");

function boardPath(noteId) {
  // The app names board files with Swift's uppercase uuidString — match it so
  // both sides hit the same file even on case-sensitive volumes.
  return path.join(EXCALIDRAW_DIR, `${String(noteId).toUpperCase()}.excalidraw.json`);
}

function readBoard(noteId) {
  try {
    return JSON.parse(fs.readFileSync(boardPath(noteId), "utf8"));
  } catch {
    return null;
  }
}

function writeBoard(noteId, scene) {
  fs.mkdirSync(EXCALIDRAW_DIR, { recursive: true });
  writeJSON(boardPath(noteId), scene);
}

function boardHasContent(noteId) {
  const scene = readBoard(noteId);
  return !!(scene && Array.isArray(scene.elements) && scene.elements.some((e) => !e.isDeleted));
}

function randomId() {
  return require("crypto").randomBytes(8).toString("hex");
}

function randomSeed() {
  return Math.floor(Math.random() * 2 ** 31);
}

function baseElement(type, x, y, width, height, opts = {}) {
  return {
    id: opts.id || randomId(),
    type,
    x, y, width, height,
    angle: 0,
    strokeColor: opts.strokeColor || "#1e1e1e",
    backgroundColor: opts.backgroundColor || "transparent",
    fillStyle: "solid",
    strokeWidth: 2,
    strokeStyle: "solid",
    roughness: 1,
    opacity: 100,
    groupIds: [],
    frameId: null,
    roundness: type === "rectangle" ? { type: 3 } : type === "arrow" || type === "line" ? { type: 2 } : null,
    seed: randomSeed(),
    version: 1,
    versionNonce: randomSeed(),
    isDeleted: false,
    boundElements: [],
    updated: Date.now(),
    link: null,
    locked: false,
  };
}

function textElement(text, x, y, opts = {}) {
  const fontSize = opts.fontSize || 20;
  const lines = String(text).split("\n");
  const width = Math.max(...lines.map((l) => l.length), 1) * fontSize * 0.6;
  const height = lines.length * fontSize * 1.25;
  const el = baseElement("text", x, y, width, height, opts);
  Object.assign(el, {
    text: String(text),
    fontSize,
    fontFamily: 1,
    textAlign: opts.containerId ? "center" : "left",
    verticalAlign: opts.containerId ? "middle" : "top",
    containerId: opts.containerId || null,
    originalText: String(text),
    autoResize: true,
    lineHeight: 1.25,
  });
  return el;
}

/// Point on `rect`'s boundary along the line from its center toward `toward`,
/// so arrows visually start/end at shape edges instead of centers.
function edgePoint(rect, toward) {
  const cx = rect.x + rect.width / 2;
  const cy = rect.y + rect.height / 2;
  const dx = toward.x - cx;
  const dy = toward.y - cy;
  if (dx === 0 && dy === 0) return { x: cx, y: cy };
  const sx = dx !== 0 ? rect.width / 2 / Math.abs(dx) : Infinity;
  const sy = dy !== 0 ? rect.height / 2 / Math.abs(dy) : Infinity;
  const s = Math.min(sx, sy);
  return { x: cx + dx * s, y: cy + dy * s };
}

function center(rect) {
  return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
}

function bbox(elements) {
  const live = elements.filter((e) => !e.isDeleted);
  if (live.length === 0) return null;
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const e of live) {
    minX = Math.min(minX, e.x);
    minY = Math.min(minY, e.y);
    maxX = Math.max(maxX, e.x + (e.width || 0));
    maxY = Math.max(maxY, e.y + (e.height || 0));
  }
  return { minX, minY, maxX, maxY };
}

/// Convert the simplified `shapes` input into Excalidraw elements.
/// `existingById` lets arrows bind to elements already on the board.
/// Throws Error with a human-readable message on invalid input.
function shapesToElements(shapes, existingById) {
  const out = [];
  const byId = new Map(); // friendly/new id -> element (new shapes only)

  const resolveRef = (ref, role, shapeIdx) => {
    if (typeof ref === "object" && ref !== null) return { point: ref };
    const el = byId.get(ref) || existingById.get(ref);
    if (!el) throw new Error(`Shape #${shapeIdx}: ${role} references unknown shape id "${ref}"`);
    return { element: el };
  };

  // Pass 1: boxes and standalone text, so arrows can reference them.
  for (const s of shapes) {
    if (s.type === "arrow" || s.type === "line") continue;
    if (s.type === "text") {
      const el = textElement(s.text ?? s.label ?? "", s.x ?? 0, s.y ?? 0, {
        id: s.id, fontSize: s.fontSize, strokeColor: s.strokeColor,
      });
      out.push(el);
      if (s.id) byId.set(s.id, el);
      continue;
    }
    const el = baseElement(s.type, s.x ?? 0, s.y ?? 0, s.width ?? 160, s.height ?? 80, {
      id: s.id, strokeColor: s.strokeColor, backgroundColor: s.backgroundColor,
    });
    out.push(el);
    if (s.id) byId.set(s.id, el);
    if (s.label) {
      const t = textElement(s.label, 0, 0, {
        containerId: el.id, fontSize: s.fontSize, strokeColor: s.strokeColor,
      });
      // Center the bound label inside its container (the app re-lays it out).
      t.x = el.x + (el.width - t.width) / 2;
      t.y = el.y + (el.height - t.height) / 2;
      el.boundElements.push({ id: t.id, type: "text" });
      out.push(t);
    }
  }

  // Pass 2: arrows/lines, with edge-clipped endpoints + real bindings.
  shapes.forEach((s, idx) => {
    if (s.type !== "arrow" && s.type !== "line") return;
    if (s.start == null || s.end == null) {
      throw new Error(`Shape #${idx} (${s.type}): "start" and "end" are required (shape id or {x,y})`);
    }
    const start = resolveRef(s.start, "start", idx);
    const end = resolveRef(s.end, "end", idx);
    const startAnchor = start.element ? center(start.element) : start.point;
    const endAnchor = end.element ? center(end.element) : end.point;
    const p1 = start.element ? edgePoint(start.element, endAnchor) : startAnchor;
    const p2 = end.element ? edgePoint(end.element, startAnchor) : endAnchor;

    const el = baseElement(s.type, p1.x, p1.y, Math.abs(p2.x - p1.x), Math.abs(p2.y - p1.y), {
      id: s.id, strokeColor: s.strokeColor,
    });
    Object.assign(el, {
      points: [[0, 0], [p2.x - p1.x, p2.y - p1.y]],
      lastCommittedPoint: null,
      startArrowhead: null,
      endArrowhead: s.type === "arrow" ? "arrow" : null,
      startBinding: start.element ? { elementId: start.element.id, focus: 0, gap: 4 } : null,
      endBinding: end.element ? { elementId: end.element.id, focus: 0, gap: 4 } : null,
      elbowed: false,
    });
    // Reciprocal binding entries so the connector follows dragged shapes.
    for (const bound of [start.element, end.element]) {
      if (!bound) continue;
      bound.boundElements = bound.boundElements || [];
      bound.boundElements.push({ id: el.id, type: "arrow" });
    }
    out.push(el);
    if (s.id) byId.set(s.id, el);
    if (s.label) {
      const t = textElement(s.label, 0, 0, { containerId: el.id, fontSize: s.fontSize, strokeColor: s.strokeColor });
      t.x = (p1.x + p2.x) / 2 - t.width / 2;
      t.y = (p1.y + p2.y) / 2 - t.height / 2;
      el.boundElements.push({ id: t.id, type: "text" });
      out.push(t);
    }
  });

  return out;
}

/// One-line human summary of a board element (for read_board).
function describeElement(el, elements) {
  const label =
    el.type === "text"
      ? el.text
      : (() => {
          const boundText = (el.boundElements || [])
            .filter((b) => b.type === "text")
            .map((b) => elements.find((e) => e.id === b.id))
            .find((e) => e && !e.isDeleted);
          return boundText ? boundText.text : null;
        })();
  const geo = `at (${Math.round(el.x)}, ${Math.round(el.y)}) size ${Math.round(el.width || 0)}×${Math.round(el.height || 0)}`;
  return `- ${el.type} [id: ${el.id}] ${label ? `"${label}" ` : ""}${geo}`;
}

// --- MCP Server ---

const MCP_VERSION = "1.4.0";

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

server.tool("list_notes", "List all FloatNote tabs with their IDs and titles. Each tab has: id (UUID), title, html (content), recordingPath (optional .m4a path for audio recordings). Notes with a non-empty attached whiteboard are marked [has diagram] (see read_board / draw_on_board).", {}, async () => {
  const tabs = readTabs();
  if (tabs.length === 0) {
    return { content: [{ type: "text", text: `FloatNote MCP v${MCP_VERSION} — No notes found.` }] };
  }
  const list = tabs
    .map((t, i) => `${i + 1}. [${t.id}] ${t.title}${boardHasContent(t.id) ? " [has diagram]" : ""}`)
    .join("\n");
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
    const boardNote = boardHasContent(tab.id)
      ? `\n\n[This note has an attached whiteboard diagram — use read_board to inspect it or draw_on_board to modify it.]`
      : "";
    return {
      content: [
        {
          type: "text",
          text: `# ${tab.title}\nID: ${tab.id}\n\n${text || "(empty note)"}${boardNote}`,
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

// --- Excalidraw board tools ---

const shapeSchema = z.object({
  type: z.enum(["rectangle", "ellipse", "diamond", "text", "arrow", "line"]).describe("Shape kind"),
  id: z.string().optional().describe("Optional friendly id (e.g. 'box1') so arrows can reference this shape via start/end"),
  x: z.number().optional().describe("Left edge (canvas px). Required for boxes and text"),
  y: z.number().optional().describe("Top edge (canvas px). Required for boxes and text"),
  width: z.number().optional().describe("Box width (default 160)"),
  height: z.number().optional().describe("Box height (default 80)"),
  label: z.string().optional().describe("Text rendered centered inside a box, or on an arrow/line"),
  text: z.string().optional().describe("Content for standalone 'text' shapes"),
  start: z.union([z.string(), z.object({ x: z.number(), y: z.number() })]).optional()
    .describe("Arrow/line origin: a shape id (binds the connector so it follows the shape) or an {x,y} point"),
  end: z.union([z.string(), z.object({ x: z.number(), y: z.number() })]).optional()
    .describe("Arrow/line target: a shape id or an {x,y} point"),
  strokeColor: z.string().optional().describe("Hex stroke color (default #1e1e1e, auto-inverts in dark theme)"),
  backgroundColor: z.string().optional().describe("Hex fill color (default transparent)"),
  fontSize: z.number().optional().describe("Label/text font size (default 20)"),
});

server.tool(
  "draw_on_board",
  "Draw a diagram on a note's attached Excalidraw whiteboard. EVERY FloatNote note has its own whiteboard — when asked to add a diagram, flowchart, sketch, architecture drawing, or any visual to a note, use this tool; do NOT put ASCII art in the note text. Shapes use simple primitives; arrows can connect shapes by id and stay attached when shapes are moved. The app shows the result live (the board auto-opens if the note is active). Typical flowchart: rectangles with labels + arrows with start/end ids, laid out top-to-bottom with ~80px gaps.",
  {
    identifier: z.string().describe("Note ID (UUID) or note title"),
    mode: z.enum(["replace", "add"]).describe("'replace' clears the board first; 'add' appends (auto-shifted below existing content if overlapping). Use read_board first when adding or editing"),
    shapes: z.array(shapeSchema).describe("Shapes to draw. Empty array with mode 'replace' clears the board"),
  },
  async ({ identifier, mode, shapes }) => {
    const tabs = readTabs();
    const tab =
      tabs.find((t) => t.id === identifier) ||
      tabs.find((t) => t.title.toLowerCase() === identifier.toLowerCase()) ||
      tabs.find((t) => t.title.toLowerCase().includes(identifier.toLowerCase()));
    if (!tab) {
      return { content: [{ type: "text", text: `Note not found: "${identifier}"` }] };
    }

    const existing = readBoard(tab.id) || { elements: [], appState: {}, files: {} };
    const existingElements = Array.isArray(existing.elements) ? existing.elements : [];
    const keptElements = mode === "add" ? existingElements : [];
    const existingById = new Map(keptElements.filter((e) => !e.isDeleted).map((e) => [e.id, e]));

    let newElements;
    try {
      newElements = shapesToElements(shapes, existingById);
    } catch (e) {
      return { content: [{ type: "text", text: `Invalid shapes: ${e.message}` }] };
    }

    // In add mode, never draw over existing content: if the new elements'
    // bounding box intersects the board's, shift the new ones below it.
    if (mode === "add" && newElements.length > 0) {
      const oldBox = bbox(keptElements);
      const newBox = bbox(newElements);
      if (oldBox && newBox &&
          newBox.minX < oldBox.maxX && newBox.maxX > oldBox.minX &&
          newBox.minY < oldBox.maxY && newBox.maxY > oldBox.minY) {
        const dy = oldBox.maxY + 80 - newBox.minY;
        for (const el of newElements) el.y += dy;
      }
    }

    writeBoard(tab.id, {
      elements: keptElements.concat(newElements),
      appState: existing.appState || {},
      files: existing.files || {},
    });

    const verb = mode === "replace" ? "Replaced board with" : "Added";
    return {
      content: [{
        type: "text",
        text: `${verb} ${shapes.length} shape(s) on the whiteboard of "${tab.title}" (${tab.id}). FloatNote picks it up within ~2s and opens the board if that note is active.`,
      }],
    };
  }
);

server.tool(
  "read_board",
  "Read a note's attached Excalidraw whiteboard: lists every element with its id, label, position and size, plus the overall bounding box. Use before draw_on_board with mode 'add' to pick free space, or to find element ids to connect arrows to.",
  {
    identifier: z.string().describe("Note ID (UUID) or note title"),
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

    const scene = readBoard(tab.id);
    const live = scene && Array.isArray(scene.elements) ? scene.elements.filter((e) => !e.isDeleted) : [];
    if (live.length === 0) {
      return { content: [{ type: "text", text: `The whiteboard of "${tab.title}" is empty.` }] };
    }

    const box = bbox(live);
    const lines = live
      .filter((e) => !(e.type === "text" && e.containerId)) // bound labels shown with their container
      .map((e) => describeElement(e, live));
    return {
      content: [{
        type: "text",
        text:
          `Whiteboard of "${tab.title}" (${tab.id}) — ${live.length} element(s), ` +
          `bounding box (${Math.round(box.minX)}, ${Math.round(box.minY)}) → (${Math.round(box.maxX)}, ${Math.round(box.maxY)}):\n\n` +
          lines.join("\n") +
          `\n\nShape ids can be used as arrow start/end in draw_on_board (mode 'add').`,
      }],
    };
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);

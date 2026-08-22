#!/usr/bin/env node

const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");
const fs = require("fs");
const path = require("path");
const os = require("os");

const TABS_PATH = path.join(os.homedir(), ".floatnote-tabs.json");
const FOLDERS_PATH = path.join(os.homedir(), ".floatnote-folders.json");
const IMAGES_DIR = path.join(os.homedir(), ".floatnote-images");

// Inline images are stored as PNGs and referenced from a note's HTML by the
// plain-text marker ⟦img:<uuid>:<width>⟧ (the Cocoa HTML exporter drops real
// attachments, so the app persists markers instead — see Images.swift).
const IMG_MARKER_RE = /⟦img:([0-9A-Fa-f-]{36}):(\d+)⟧/g;
// Guardrails so reading an image-heavy note can't flood the context.
const MAX_INLINE_IMAGES = 8;
const MAX_IMAGE_EDGE = 1568; // px; Claude downsamples beyond this anyway

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

/// Base64 PNG for a file on disk, downscaled via macOS `sips` when it's larger
/// than MAX_IMAGE_EDGE so a 4K capture doesn't cost a fortune in tokens.
/// Returns null when the file is missing or unreadable.
function pngBase64AtPath(src) {
  if (!src || !fs.existsSync(src)) return null;
  let tmp = null;
  try {
    const { execFileSync } = require("child_process");
    tmp = path.join(os.tmpdir(), `floatnote-mcp-${process.pid}-${Date.now()}.png`);
    // -Z resizes only if the long edge exceeds the limit (aspect preserved).
    execFileSync("/usr/bin/sips", ["-Z", String(MAX_IMAGE_EDGE), src, "--out", tmp], {
      stdio: "ignore",
    });
    return fs.readFileSync(tmp).toString("base64");
  } catch {
    // sips unavailable or failed — fall back to the original bytes.
    try { return fs.readFileSync(src).toString("base64"); } catch { return null; }
  } finally {
    if (tmp) { try { fs.unlinkSync(tmp); } catch {} }
  }
}

/// Base64 PNG for one of a note's inline images, by image id.
function imageBase64(id) {
  return pngBase64AtPath(path.join(IMAGES_DIR, `${id.toUpperCase()}.png`));
}

/// Split a note's text into readable text (markers replaced by [image N]
/// placeholders) plus the MCP image content blocks to append after it.
function extractImages(text) {
  const ids = [];
  const labeled = text.replace(IMG_MARKER_RE, (_m, id) => {
    ids.push(id);
    return `[image ${ids.length}]`;
  });
  const blocks = [];
  const notes = [];
  ids.slice(0, MAX_INLINE_IMAGES).forEach((id, i) => {
    const data = imageBase64(id);
    if (data) blocks.push({ type: "image", data, mimeType: "image/png" });
    else notes.push(`[image ${i + 1}: file missing on disk]`);
  });
  if (ids.length > MAX_INLINE_IMAGES) {
    notes.push(
      `[${ids.length - MAX_INLINE_IMAGES} more image(s) in this note were not inlined (cap: ${MAX_INLINE_IMAGES}).]`
    );
  }
  return { text: labeled, blocks, notes };
}

function stripHTML(html) {
  return html
    // Drop <style>/<script> BODIES first — stripping tags alone would leave
    // their CSS/JS text in the output (Cocoa's exporter emits a <style> block).
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
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

const MCP_VERSION = "1.6.0";

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
  "Read the content of a FloatNote tab by ID or title. Returns plain text, with any inline images attached as image blocks ([image N] placeholders mark where they sit in the text).",
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

    // Inline images: markers become [image N] placeholders in the text and the
    // pictures themselves follow as image content blocks, in the same order.
    const { text, blocks, notes } = extractImages(stripHTML(tab.html));
    const boardNote = boardHasContent(tab.id)
      ? `\n\n[This note has an attached whiteboard diagram — use read_board to inspect it or draw_on_board to modify it.]`
      : "";
    const imgNote = notes.length ? `\n\n${notes.join("\n")}` : "";
    return {
      content: [
        {
          type: "text",
          text: `# ${tab.title}\nID: ${tab.id}\n\n${text || "(empty note)"}${boardNote}${imgNote}`,
        },
        ...blocks,
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
  "set_note_status",
  "Mark a FloatNote note as busy (a job is running on it) or clear the flag. While set, the note's sidebar row shows a pulsing blue indicator with the status text on hover. Pass a status string like 'Claude working…' to set; omit status (or pass empty) to clear. Statuses expire after 30 minutes — long-running jobs should re-set periodically to stay alive. ALWAYS clear the status when the job finishes.",
  {
    identifier: z.string().describe("Tab ID (UUID) or tab title to search for"),
    status: z.string().optional().describe("Busy label to show (e.g. 'Claude working…'). Omit or pass empty string to clear."),
  },
  async ({ identifier, status }) => {
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

    if (status && status.trim() !== "") {
      tabs[idx].jobStatus = status;
      tabs[idx].jobStatusAt = Date.now() / 1000; // epoch seconds, matches Swift's timeIntervalSince1970
    } else {
      tabs[idx].jobStatus = null;
      tabs[idx].jobStatusAt = null;
    }
    writeTabs(tabs);

    const verb = status && status.trim() !== "" ? `set to "${status}"` : "cleared";
    return {
      content: [
        {
          type: "text",
          text: `Status ${verb} on "${tabs[idx].title}" (${tabs[idx].id}). FloatNote picks it up within ~2s.`,
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

// --- Browser panel (RPC into the running app) ---
//
// FloatNote's browser panel is a WKWebView living inside the app, so the APP —
// not this node process — is what can drive it. Calls travel over the same
// file-spool pattern the rest of FloatNote uses (see External File Sync in
// CLAUDE.md), in ~/.floatnote-browser-rpc/:
//
//   <uuid>.req.json   written here, temp+rename
//   <uuid>.res.json   written by FloatNote, which then deletes the request
//
// Request:  { id, action, params, ts }              ts in epoch SECONDS
// Response: { id, ok: true, result } | { id, ok: false, error }
//
// Write actions (click/type/eval) can be refused by the app itself when
// fn.browserAllowClaudeWrites is off; that arrives as ok:false and is surfaced
// verbatim rather than swallowed.

// FLOATNOTE_BROWSER_RPC_DIR exists so a test harness can stand in for the app
// without touching the real spool; unset (the normal case) means the app's dir.
const BROWSER_RPC_DIR =
  process.env.FLOATNOTE_BROWSER_RPC_DIR || path.join(os.homedir(), ".floatnote-browser-rpc");
const RPC_TIMEOUT_MS = 20000;      // default: navigation resolves on didFinish
const RPC_SLOW_TIMEOUT_MS = 35000; // screenshot / wait legitimately block longer
const RPC_POLL_MS = 60;            // sleep between checks — never a busy spin
const RPC_STALE_MS = 120000;       // > the longest timeout, so only real orphans
const BROWSER_UNREACHABLE =
  "FloatNote isn't running, or its browser panel has never been opened.";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// Drop undefined entries so an omitted optional param isn't sent as null.
function compact(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) if (v !== undefined) out[k] = v;
  return out;
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}

/// Delete request/response files nobody can still be waiting on. Keeps a
/// crashed call from leaving a request the app would answer minutes later, or
/// an answer that would never be read.
function sweepStaleRPC() {
  let names;
  try { names = fs.readdirSync(BROWSER_RPC_DIR); } catch { return; }
  const cutoff = Date.now() - RPC_STALE_MS;
  for (const name of names) {
    if (!/\.(req|res)\.json$/.test(name)) continue;
    const p = path.join(BROWSER_RPC_DIR, name);
    try { if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p); } catch {}
  }
}

/// One request/response round trip. Never throws and never reports a silent
/// success: returns {ok:true, result} or {ok:false, error, unreachable?}.
async function browserRPC(action, params = {}, timeoutMs = RPC_TIMEOUT_MS) {
  const id = require("crypto").randomUUID().toUpperCase();
  const reqPath = path.join(BROWSER_RPC_DIR, `${id}.req.json`);
  // The app may name the reply from Swift's UUID.uuidString (uppercase) or echo
  // the id verbatim — watch both spellings so a case-sensitive volume still works.
  const resPaths = [`${id}.res.json`, `${id.toLowerCase()}.res.json`]
    .map((n) => path.join(BROWSER_RPC_DIR, n));

  try {
    fs.mkdirSync(BROWSER_RPC_DIR, { recursive: true });
    sweepStaleRPC();
    // temp+rename: a plain writeFileSync fails silently under sandboxing, and a
    // half-written request would be parsed by the app's watcher mid-write.
    writeJSON(reqPath, { id, action, params, ts: Math.floor(Date.now() / 1000) });
  } catch (e) {
    return { ok: false, error: `could not queue the request: ${e.message}` };
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(RPC_POLL_MS);
    for (const resPath of resPaths) {
      let raw;
      try { raw = fs.readFileSync(resPath, "utf8"); } catch { continue; }
      // The reply is ours to clean up (the app only deletes the request).
      try { fs.unlinkSync(resPath); } catch {}
      try { fs.unlinkSync(reqPath); } catch {}
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch (e) {
        return { ok: false, error: `FloatNote wrote an unreadable response (${e.message})` };
      }
      if (msg && msg.ok) return { ok: true, result: msg.result || {} };
      return { ok: false, error: (msg && msg.error) || "no reason given" };
    }
  }

  // Nothing answered: retract the request so a late-waking app can't replay it.
  try { fs.unlinkSync(reqPath); } catch {}
  return { ok: false, unreachable: true, error: BROWSER_UNREACHABLE };
}

/// Readable text for a failed call, carrying the app's own error string.
function rpcError(action, res) {
  return res.unreachable ? BROWSER_UNREACHABLE : `browser ${action} failed: ${res.error}`;
}

/// Best-effort URL for labelling a screenshot when the app's result omits one.
/// Never fails the caller — a null just means "no URL to print".
async function browserTabURL(id) {
  const res = await browserRPC("tabs", {}, 5000);
  if (!res.ok) return null;
  const tabs = Array.isArray(res.result.tabs) ? res.result.tabs : [];
  const tab = id ? tabs.find((t) => t.id === id) : tabs.find((t) => t.active) || tabs[0];
  return tab ? tab.url || null : null;
}

const TAB_ID_PARAM = "Tab id from browser_tabs. Omit to act on the active tab";

server.tool(
  "browser_tabs",
  "List the tabs open in FloatNote's own browser panel — the WKWebView column beside the terminal, NOT Safari/Chrome/Playwright. Returns each tab's id, URL, title and which one is active. Pass `activate` with a tab id to switch to that tab first. The ids returned here are what every other browser_* tool takes as `id`.",
  {
    activate: z.string().optional().describe("Tab id to make the active tab before listing (optional)"),
  },
  async ({ activate }) => {
    let prefix = "";
    if (activate) {
      const act = await browserRPC("activate", { id: activate });
      if (!act.ok) return textResult(rpcError("activate", act));
      prefix = `Activated tab ${act.result.id || activate}.\n\n`;
    }
    const res = await browserRPC("tabs");
    if (!res.ok) return textResult(rpcError("tabs", res));
    const tabs = Array.isArray(res.result.tabs) ? res.result.tabs : [];
    if (tabs.length === 0) {
      return textResult(`${prefix}FloatNote's browser panel has no open tabs — use browser_open to open a page.`);
    }
    const list = tabs
      .map((t, i) => `${i + 1}. [${t.id}]${t.active ? " (active)" : ""} ${t.title || "(untitled)"}\n   ${t.url || ""}`)
      .join("\n");
    return textResult(`${prefix}FloatNote browser — ${tabs.length} tab(s):\n\n${list}`);
  }
);

server.tool(
  "browser_open",
  "Open a URL in FloatNote's own browser panel (the browser column inside the app, not the system browser) and wait until the page has finished loading, so a following browser_read/browser_screenshot needs no sleep. The panel appears in the app if it was hidden.",
  {
    url: z.string().describe("URL to open. A bare host gets https:// prepended; text that isn't a URL becomes a DuckDuckGo search"),
    newTab: z.boolean().optional().describe("Open in a new tab (default true). false navigates the active tab instead"),
  },
  async ({ url, newTab }) => {
    const res = await browserRPC("open", compact({ url, newTab }));
    if (!res.ok) return textResult(rpcError("open", res));
    const r = res.result;
    return textResult(`Opened ${r.url || url} in FloatNote's browser panel (tab ${r.id || "?"}). The page has finished loading.`);
  }
);

server.tool(
  "browser_read",
  "Read the current page in FloatNote's own browser panel as text (default) or raw HTML. Use this after browser_open/browser_click to see what the page actually says. Long pages are cut at maxChars and the result says so.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    format: z.enum(["text", "html"]).optional().describe("'text' (default) = the page's visible text; 'html' = its serialized DOM"),
    maxChars: z.number().optional().describe("Maximum characters of content to return (default 60000)"),
  },
  async ({ id, format, maxChars }) => {
    const fmt = format || "text";
    const cap = maxChars === undefined ? 60000 : maxChars;
    const res = await browserRPC("read", compact({ id, format: fmt, maxChars: cap }));
    if (!res.ok) return textResult(rpcError("read", res));
    const r = res.result;
    const body = typeof r.content === "string" ? r.content : JSON.stringify(r.content ?? "");
    const head =
      `${r.title || "(untitled)"}\n${r.url || ""}\nformat: ${r.format || fmt}` +
      (r.truncated
        ? `\ntruncated: true — content was cut at ${cap} chars. Re-read with a larger maxChars, or use browser_eval to pull just the part you need.`
        : "");
    const tail = r.truncated ? `\n\n[… TRUNCATED at ${cap} chars …]` : "";
    return textResult(`${head}\n\n${body || "(no content)"}${tail}`);
  }
);

server.tool(
  "browser_click",
  "Click an element on the page in FloatNote's own browser panel, either by CSS selector or by its visible text (case-insensitive, over links, buttons, [role=button], submit inputs, summary and [onclick]). A miss is reported as a failure with the selector echoed, never as a silent success. Refused when write access is disabled in FloatNote's browser settings.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    selector: z.string().optional().describe("CSS selector of the element to click"),
    text: z.string().optional().describe("Visible text to match instead of a selector"),
  },
  async ({ id, selector, text }) => {
    if (!selector && !text) {
      return textResult("browser_click needs either a `selector` or a `text` to match.");
    }
    const res = await browserRPC("click", compact({ id, selector, text }));
    if (!res.ok) return textResult(rpcError("click", res));
    const r = res.result;
    return textResult(`Clicked ${r.matched || selector || text}. Use browser_read to see the resulting page.`);
  }
);

server.tool(
  "browser_type",
  "Type text into a form field on the page in FloatNote's own browser panel, optionally submitting the form afterwards. Refused when write access is disabled in FloatNote's browser settings.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    selector: z.string().describe("CSS selector of the input/textarea/contenteditable to type into"),
    text: z.string().describe("Text to enter (replaces the field's current value)"),
    submit: z.boolean().optional().describe("Submit the field's form after typing (default false)"),
  },
  async ({ id, selector, text, submit }) => {
    const res = await browserRPC("type", compact({ id, selector, text, submit }));
    if (!res.ok) return textResult(rpcError("type", res));
    const n = res.result.typed;
    return textResult(
      `Typed ${n === undefined ? text.length : n} character(s) into ${selector}` +
        (submit ? " and submitted the form." : ".")
    );
  }
);

server.tool(
  "browser_eval",
  "Run JavaScript in the page loaded in FloatNote's own browser panel and return its value (JSON-encoded, capped at ~20k chars). Good for pulling one value out of a page instead of reading the whole thing. Refused when write access is disabled in FloatNote's browser settings.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    js: z.string().describe("JavaScript expression or statement block; the completion value is returned"),
  },
  async ({ id, js }) => {
    const res = await browserRPC("eval", compact({ id, js }));
    if (!res.ok) return textResult(rpcError("eval", res));
    const v = res.result.value;
    const shown = v === undefined || v === null ? "(no value)" : typeof v === "string" ? v : JSON.stringify(v);
    return textResult(shown);
  }
);

server.tool(
  "browser_screenshot",
  "Screenshot the page in FloatNote's own browser panel and return the PNG inline, so you see the rendered page rather than a file path. Use it to check layout, or when a page's text alone doesn't tell you what happened.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    fullPage: z.boolean().optional().describe("Capture the whole scrollable page instead of just the visible area (default false)"),
  },
  async ({ id, fullPage }) => {
    const res = await browserRPC("screenshot", compact({ id, fullPage }), RPC_SLOW_TIMEOUT_MS);
    if (!res.ok) return textResult(rpcError("screenshot", res));
    const shotPath = res.result.path;
    // Same downscale guardrail as a note's inline images (MAX_IMAGE_EDGE).
    const data = shotPath ? pngBase64AtPath(shotPath) : null;
    const url = res.result.url || (await browserTabURL(id));
    if (!data) {
      return textResult(
        `FloatNote reported a screenshot${shotPath ? ` at ${shotPath}` : ""} but the PNG could not be read.`
      );
    }
    return {
      content: [
        {
          type: "text",
          text: `Screenshot of ${url || "FloatNote's browser panel"}${fullPage ? " (full page)" : ""} — ${shotPath}`,
        },
        { type: "image", data, mimeType: "image/png" },
      ],
    };
  }
);

server.tool(
  "browser_navigate",
  "Move around in FloatNote's own browser panel: pass `url` to go to a page in the current tab, or `direction` ('back', 'forward', 'reload') to move through that tab's history. Exactly one of the two. Resolves once the page has finished loading.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    url: z.string().optional().describe("Navigate the tab to this URL. Mutually exclusive with `direction`"),
    direction: z.enum(["back", "forward", "reload"]).optional().describe("History move instead of a URL. Mutually exclusive with `url`"),
  },
  async ({ id, url, direction }) => {
    if (url && direction) {
      return textResult("browser_navigate takes either `url` or `direction`, not both.");
    }
    if (!url && !direction) {
      return textResult("browser_navigate needs a `url` to go to, or a `direction` ('back', 'forward', 'reload').");
    }
    const action = url ? "navigate" : direction;
    const res = await browserRPC(action, compact({ id, url }));
    if (!res.ok) return textResult(rpcError(action, res));
    const r = res.result;
    const where = r.url || url || "(unknown URL)";
    return textResult(url ? `Navigated to ${where}.` : `Went ${direction} — now at ${where}.`);
  }
);

server.tool(
  "browser_wait",
  "Wait for something on the page in FloatNote's own browser panel: for a selector to appear, or just for a number of milliseconds. Use it when a click kicks off client-side rendering that browser_open's load-finished signal doesn't cover.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    selector: z.string().optional().describe("CSS selector to wait for. Omit to simply wait out `ms`"),
    ms: z.number().optional().describe("Milliseconds to wait / give up after (default 1000, max 15000)"),
  },
  async ({ id, selector, ms }) => {
    const res = await browserRPC("wait", compact({ id, selector, ms }), RPC_SLOW_TIMEOUT_MS);
    if (!res.ok) return textResult(rpcError("wait", res));
    const r = res.result;
    const waited = r.waitedMs === undefined ? "" : ` after ${r.waitedMs}ms`;
    if (!selector) return textResult(`Waited${waited}.`);
    return textResult(r.found ? `Found ${selector}${waited}.` : `Did not find ${selector}${waited}.`);
  }
);

server.tool(
  "browser_annotate",
  "Draw a labelled box ON the page in FloatNote's browser panel, so the person watching can see exactly what you are pointing at. Give a `selector` (the box tracks that element) or a page-coordinate `rect`. The box appears in browser_screenshot and in browser_annotations, and survives until the page navigates. Counts as a write action.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    selector: z.string().optional().describe("CSS selector to box. Mutually exclusive with rect"),
    rect: z
      .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
      .optional()
      .describe("Page-coordinate rectangle to box, when no element matches what you mean"),
    note: z.string().optional().describe("Short label drawn on the box — say what is wrong or interesting"),
    color: z.enum(["coral", "yellow", "blue", "green"]).optional().describe("Box colour (default coral)"),
  },
  async ({ id, selector, rect, note, color }) => {
    if (!selector && !rect) {
      return textResult("browser_annotate needs either a `selector` or a `rect`.");
    }
    const res = await browserRPC("annotate", compact({ id, selector, rect, note, color }));
    if (!res.ok) return textResult(rpcError("annotate", res));
    const a = res.result.annotation || {};
    const where = a.selector ? `selector ${a.selector}` : `rect ${JSON.stringify(a.rect)}`;
    return textResult(
      `Annotation ${a.index} drawn on ${where}${a.note ? ` — "${a.note}"` : ""}.` +
        (a.text ? `\nIt covers: ${a.text}` : "") +
        `\nIt is visible in the panel now and will appear in browser_screenshot.`
    );
  }
);

server.tool(
  "browser_annotations",
  "List the annotations on the page in FloatNote's browser panel — both the ones you drew with browser_annotate and the ones the person drew by hand with the pane's pencil tool. Use it to read what they marked and what they wrote on it.",
  { id: z.string().optional().describe(TAB_ID_PARAM) },
  async ({ id }) => {
    const res = await browserRPC("annotations", compact({ id }));
    if (!res.ok) return textResult(rpcError("annotations", res));
    const list = Array.isArray(res.result.annotations) ? res.result.annotations : [];
    if (!list.length) {
      return textResult(`No annotations on ${res.result.url || "the page"}.`);
    }
    const lines = list.map((a) => {
      const by = a.source === "user" ? "drawn by the user" : "yours";
      const rect = a.rect ? `${a.rect.w}×${a.rect.h} at ${a.rect.x},${a.rect.y}` : "?";
      return `${a.index}. [${by}] ${a.note || "(no note)"}\n   ${rect}${a.selector ? ` · ${a.selector}` : ""}${a.text ? `\n   covers: ${a.text}` : ""}`;
    });
    return textResult(`${list.length} annotation(s) on ${res.result.url}:\n\n${lines.join("\n")}`);
  }
);

server.tool(
  "browser_annotate_clear",
  "Remove annotations from the page in FloatNote's browser panel: one by index, or all of them when no index is given. Counts as a write action.",
  {
    id: z.string().optional().describe(TAB_ID_PARAM),
    index: z.number().optional().describe("Annotation index from browser_annotations. Omit to clear every one"),
  },
  async ({ id, index }) => {
    const res = await browserRPC("annotate_clear", compact({ id, index }));
    if (!res.ok) return textResult(rpcError("annotate_clear", res));
    const n = res.result.cleared || 0;
    return textResult(n ? `Cleared ${n} annotation(s).` : "Nothing to clear.");
  }
);

server.tool(
  "browser_device",
  "Switch the viewport FloatNote's browser panel renders in — a phone, a tablet, or the full panel width — the way Chrome DevTools' device toolbar does. It sets both the CSS viewport size AND the matching user agent, then reloads the tab, so a site that decides mobile-vs-desktop on the server serves its mobile page. Call it with no arguments to read the current viewport and the list of presets.",
  {
    name: z
      .string()
      .optional()
      .describe("Preset name or a fragment of one, e.g. 'iPhone 15', 'Pixel', 'iPad mini', 'Desktop', 'Responsive' (full panel width)"),
    landscape: z.boolean().optional().describe("Rotate: swap width and height"),
    reload: z
      .boolean()
      .optional()
      .describe("Reload the page so a server that decides mobile-vs-desktop serves its mobile version. Default false — the page keeps its current state (forms, scroll, open widgets), and a responsive site re-lays out from the new width anyway"),
  },
  async ({ name, landscape, reload }) => {
    const res = await browserRPC("device", compact({ name, landscape, reload }));
    if (!res.ok) return textResult(rpcError("device", res));
    const r = res.result || {};
    const size = r.width ? `${r.width}×${r.height}${r.landscape ? " (landscape)" : ""}` : "full panel width";
    const list = Array.isArray(r.available) ? `\n\nPresets: ${r.available.join(", ")}` : "";
    const stale = r.userAgentStale
      ? "\nThe page on screen was loaded under the previous user agent — pass reload: true if you need the server's mobile version (its current state is lost)."
      : "";
    return textResult(
      `Viewport: ${r.name} — ${size}\nUser agent: ${r.userAgent}` +
        `\nbrowser_read / browser_screenshot now show that rendering.${stale}${list}`
    );
  }
);

server.tool(
  "browser_close",
  "Close a tab in FloatNote's own browser panel. Takes the tab id from browser_tabs.",
  {
    id: z.string().describe("Tab id to close (from browser_tabs)"),
  },
  async ({ id }) => {
    const res = await browserRPC("close", { id });
    if (!res.ok) return textResult(rpcError("close", res));
    return textResult(`Closed tab ${res.result.closed || id} in FloatNote's browser panel.`);
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);

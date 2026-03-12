const Evernote = require('evernote');
const fs = require('fs');
const path = require('path');

const TOKEN_FILE = path.join(__dirname, '.auth.json');

function loadAuth() {
  if (!fs.existsSync(TOKEN_FILE)) {
    throw new Error('No auth token found. Run: node login.js');
  }
  const auth = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf-8'));
  if (new Date(auth.expiresAt) < new Date()) {
    throw new Error('Token expired. Run: node login.js');
  }
  return auth;
}

function createClient(auth) {
  const client = new Evernote.Client({
    token: auth.monoToken,
    sandbox: false,
    serviceHost: 'www.evernote.com',
  });
  return client;
}

async function listNotebooks() {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();
  const notebooks = await noteStore.listNotebooks();
  return notebooks.map(nb => ({
    guid: nb.guid,
    name: nb.name,
    stack: nb.stack || null,
    defaultNotebook: nb.defaultNotebook || false,
    noteCount: nb.restrictions ? undefined : undefined,
  }));
}

async function listNotes(notebookGuid, offset = 0, maxNotes = 25) {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();

  const filter = new Evernote.NoteStore.NoteFilter();
  if (notebookGuid) filter.notebookGuid = notebookGuid;
  filter.order = Evernote.Types.NoteSortOrder.UPDATED;
  filter.ascending = false;

  const spec = new Evernote.NoteStore.NotesMetadataResultSpec();
  spec.includeTitle = true;
  spec.includeCreated = true;
  spec.includeUpdated = true;
  spec.includeNotebookGuid = true;
  spec.includeTagGuids = true;
  spec.includeContentLength = true;

  const result = await noteStore.findNotesMetadata(filter, offset, maxNotes, spec);
  return {
    totalNotes: result.totalNotes,
    notes: result.notes.map(n => ({
      guid: n.guid,
      title: n.title,
      created: new Date(n.created).toISOString(),
      updated: new Date(n.updated).toISOString(),
      notebookGuid: n.notebookGuid,
      tagGuids: n.tagGuids || [],
      contentLength: n.contentLength,
    })),
  };
}

async function getNote(noteGuid) {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();

  const note = await noteStore.getNote(noteGuid, true, false, false, false);
  return {
    guid: note.guid,
    title: note.title,
    content: note.content,
    created: new Date(note.created).toISOString(),
    updated: new Date(note.updated).toISOString(),
    notebookGuid: note.notebookGuid,
    tagGuids: note.tagGuids || [],
  };
}

async function createNote(title, content, notebookGuid) {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();

  const note = new Evernote.Types.Note();
  note.title = title;
  note.content = `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>${content}</en-note>`;
  if (notebookGuid) note.notebookGuid = notebookGuid;

  const created = await noteStore.createNote(note);
  return {
    guid: created.guid,
    title: created.title,
    created: new Date(created.created).toISOString(),
    notebookGuid: created.notebookGuid,
  };
}

async function updateNote(noteGuid, title, content) {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();

  const note = new Evernote.Types.Note();
  note.guid = noteGuid;
  if (title) note.title = title;
  if (content) {
    note.content = `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>${content}</en-note>`;
  }

  const updated = await noteStore.updateNote(note);
  return {
    guid: updated.guid,
    title: updated.title,
    updated: new Date(updated.updated).toISOString(),
  };
}

async function deleteNote(noteGuid) {
  const auth = loadAuth();
  const client = createClient(auth);
  const noteStore = client.getNoteStore();
  await noteStore.deleteNote(noteGuid);
  return { deleted: noteGuid };
}

module.exports = {
  loadAuth,
  listNotebooks,
  listNotes,
  getNote,
  createNote,
  updateNote,
  deleteNote,
};

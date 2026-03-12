const api = require('./evernote-api');

const [,, command, ...args] = process.argv;

async function main() {
  switch (command) {
    case 'notebooks': {
      const notebooks = await api.listNotebooks();
      console.log(`\nFound ${notebooks.length} notebooks:\n`);
      notebooks.forEach(nb => {
        const stack = nb.stack ? ` [${nb.stack}]` : '';
        const def = nb.defaultNotebook ? ' (default)' : '';
        console.log(`  ${nb.guid}  ${nb.name}${stack}${def}`);
      });
      break;
    }

    case 'notes': {
      const notebookGuid = args[0] || null;
      const result = await api.listNotes(notebookGuid);
      console.log(`\nFound ${result.totalNotes} notes${notebookGuid ? ' in notebook' : ''}:\n`);
      result.notes.forEach(n => {
        console.log(`  ${n.guid}  ${n.title}`);
        console.log(`    updated: ${n.updated}`);
      });
      break;
    }

    case 'get': {
      if (!args[0]) { console.log('Usage: node cli.js get <noteGuid>'); break; }
      const note = await api.getNote(args[0]);
      console.log(`\nTitle: ${note.title}`);
      console.log(`Created: ${note.created}`);
      console.log(`Updated: ${note.updated}`);
      console.log(`\n--- Content ---\n`);
      console.log(note.content);
      break;
    }

    case 'create': {
      if (!args[0]) { console.log('Usage: node cli.js create "Title" "Content" [notebookGuid]'); break; }
      const note = await api.createNote(args[0], args[1] || '<p>Empty note</p>', args[2]);
      console.log(`\nNote created!`);
      console.log(`  GUID: ${note.guid}`);
      console.log(`  Title: ${note.title}`);
      console.log(`  Notebook: ${note.notebookGuid}`);
      break;
    }

    case 'update': {
      if (!args[0]) { console.log('Usage: node cli.js update <noteGuid> "New Title" "New Content"'); break; }
      const note = await api.updateNote(args[0], args[1], args[2]);
      console.log(`\nNote updated!`);
      console.log(`  GUID: ${note.guid}`);
      console.log(`  Title: ${note.title}`);
      break;
    }

    case 'delete': {
      if (!args[0]) { console.log('Usage: node cli.js delete <noteGuid>'); break; }
      const result = await api.deleteNote(args[0]);
      console.log(`\nNote deleted: ${result.deleted}`);
      break;
    }

    default:
      console.log(`
Evernote Reverse API CLI

Usage:
  node cli.js notebooks                          List all notebooks
  node cli.js notes [notebookGuid]               List notes (optionally in a notebook)
  node cli.js get <noteGuid>                     Get note content
  node cli.js create "Title" "Content" [nbGuid]  Create a note
  node cli.js update <noteGuid> "Title" "Body"   Update a note
  node cli.js delete <noteGuid>                  Delete a note

First run: node login.js  (to get auth token)
      `);
  }
}

main().catch(err => {
  console.error('Error:', err.message || err);
  if (err.message?.includes('auth') || err.message?.includes('token')) {
    console.log('\nRun: node login.js  to refresh your auth token');
  }
  process.exit(1);
});

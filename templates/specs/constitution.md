# Constitution

The rules every spec in this project obeys. Written once at setup, changed rarely, by a person, in its own PR. A feature spec never edits this file; it points at it.

## Principles

1. **One home for each kind of thing.** Work is an issue, status is the board, orientation is the generated page, data is the database, design is the spec folder. A spec that needs a new kind of place says so here first.
2. **Calm and plain for people.** Everything a person sees is written for them, never a developer note.
3. **Tests prove the change.** A feature is done when its tests pass per file on the PR and the full suite stays green on main.
4. **Never delete; move aside.** A spec that retires something says where it moves.
5. **Small and bounded.** One feature per spec, one issue per task, one PR per task. A spec that touches three features is three specs.

## What every spec has

- An outcome in one or two sentences: what is true when the feature exists.
- The people it serves and what they see.
- The data it reads and writes, by name, and where that data lives.
- The setup steps it adds, which the PR also adds to `SETUP.md`.
- What it does not do.

## What a spec never has

- Issue numbers, migration names or field names in the parts a person reads.
- A status or a diary. Status is a stub in `status/stubs/`.
- Design for a feature other than its own.

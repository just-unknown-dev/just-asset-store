# Changelog

## [0.1.0] - unreleased

### Built on just_core_cli

- **No command-line tool of its own.** The store's commands are `just store ...` (and `just add` / `just remove`): a plugin of the `just` tool, run from the project with `dart run just_asset_store:just_plugin`. They gain per-command help, `--json`, `search`, `info`, `sources` and `cache`, and check their arguments before reading any catalog.
- **The project toolkit moved to just_core_cli**: the pubspec editor, overrides, semver, JSON, names, SHA-256, ZIP, HTTP, the download cache, and the transaction and lock (now one lock in `.dart_tool/just_core_cli/`, shared with `just`; journals left in `.dart_tool/just_asset_store/` by a crash are still recovered). Every old name is re-exported; `StoreFormatException`, `StoreNames` and `SourceException` are typedefs of just_core_cli's. The store's own pieces stay here: its pubspec block (`storeBlock`, with the markers projects already hold — every store edit passes it to the editor) and its trash (`StoreProject.trashRoot`, the editor's `.editor_trash/store/`, passed to every transaction it opens).

### Added

- **Catalogs:**
  - `index.json` and `just_store.json` models, with strict validation that names the failing field.
  - Fields reserved for community publishers (trust, stats, takedowns) and paid items (pricing, entitled access, download brokers).
- **Sources:**
  - Folders, and `https` catalogs with ETag caching, an offline fallback, redirects and polite retries.
  - A per-user download cache keyed by SHA-256.
- **Archives:** a ZIP reader for untrusted archives, and a reproducible ZIP writer, both on `just_deflate`. Also SHA-256.
- **The planner:**
  - dependencies and version constraints
  - checks against the project's Dart, Flutter, engine and editor versions
  - items that depend on a changed item, name and folder clashes, and developer checkouts
  - uninstall checks: code and scenes that still use the item, and dependencies nothing else needs
- **Installs:** all-or-nothing transactions with a journal, backups, rollback, crash recovery and a project lock.
- **Project files:**
  - Edits of the pubspec files' marked blocks that keep every byte outside them.
  - `pubspec_overrides.yaml` handling: write to the file pub reads, and mirror into `pubspec.yaml` when it is ignored by git.
  - The generated module and extension registries.
  - `restore` from the lockfile.
- **Creator and catalog tools:**
  - `just store pack`: reproducible archives, text files in LF, path checks.
  - `just store index build|check|codeowners`.
  - Catalog and item repository templates.

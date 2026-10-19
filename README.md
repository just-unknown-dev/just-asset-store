# just_asset_store

The core of the Just Asset Store. It reads store catalogs, downloads and checks items, and installs them into a Flutter project. It is pure Dart, with no Flutter, and depends only on `just_core_cli` (the `just` tool's toolkit) and `just_deflate`.

The editor's store window is `just_asset_store_editor`. It uses this package, as do `just store …` and a catalog's CI. All three run the same checks, so an item that passes the catalog's CI installs in the editor.

## Every store item is a package

| Kind | Installs as |
|---|---|
| `content`: art, sound, tilesets… | An asset-only package in `packages/{category}/{id}/`. Its assets are `packages/<id>/...`: the same key in the editor and the game, never rewritten. |
| `editor-extension` | A package under `dev_dependencies`, so release builds leave out its native plugins. Its modules go into the generated `lib/editor/store_modules.g.dart`. |
| `kit`: game code plus an editor part | A regular dependency. Its modules are registered as above, and its runtime `ContextExtension`s go into `lib/game/store_extensions.g.dart`. |
| `runtime-library` | A hosted pub.dev dependency. Nothing is copied. |

Items that are only on GitHub depend on each other by version. The store writes a marked `dependency_overrides` block that points each one at its installed copy. Overrides skip pub's version checks, so the store checks every constraint itself before it changes anything.

## Installing is all or nothing

Every archive is downloaded and checked before the project is touched:
- **The pin:** its SHA-256 and size must match the catalog.
- **The zip:** no zip-slip, symlinks, ZIP64 or bombs, and no names that clash on Windows.
- **The package:** its manifest and pubspec must agree with the catalog. Only allowed file types. No build hooks, platform folders, or path or git dependencies. Content assets must sit where Flutter ships them.

Then, with a journal written ahead of each step, the store:
1. backs up every file it will change
2. stages the new folders and swaps them in
3. edits only its own marked blocks in the pubspec files, keeping comments, BOM and each line's ending
4. runs `dart pub get`
5. regenerates the registry files
6. writes `just_store.lock.json`

If any step fails, everything is put back byte for byte. A crash part-way is rolled back the next time the store runs.

## `just store`

The store has no command-line tool of its own: its commands are a plugin of the `just` tool (just_core_cli). `just` finds them in the project's packages and runs them with `dart run just_asset_store:just_plugin`, so a project always uses the store version it locked. `just add` and `just remove` are shortcuts for `just store install` and `just store uninstall`. Outside a project (a catalog's or an item's CI), activate both globally: `dart pub global activate just_core_cli` and `dart pub global activate --source git https://github.com/just-unknown-dev/just-asset-store`.

```text
just store install just_art_knight
just store update
just store uninstall just_art_knight
just store restore            # folders missing after a clone
just store generate --check   # for CI

just store pack <folder> -o dist --url <release url>
just store index build <catalog repo> -o site
just store index check <catalog repo> --download
```

`templates/catalog` is a ready catalog repository (GitHub Pages, PR validation, CODEOWNERS). `templates/item` is a ready item repository, with a release workflow.

## The library

```dart
final store = AssetStore(project: StoreProject('.'), cacheDir: StorePaths.defaultCacheDir());
final loaded = await store.loadCatalog();
final plan = (await store.planner(catalog: loaded.catalog)).install('just_art_knight');
// Show plan.changes and plan.issues; then:
final result = await store.installer().apply(plan, onProgress: print);
```

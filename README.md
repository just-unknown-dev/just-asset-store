# just_asset_store

The core of the Just Asset Store. It reads store catalogs, downloads and checks items, and installs them into a Just Game Engine project (one with `just_game_engine` and `just_game_engine_editor`) as packages. It is pure Dart, with no Flutter, and builds on [`just_core_cli`](https://pub.dev/packages/just_core_cli).

The editor's store window is part of `just_game_engine_editor` (from 0.1.0-dev.2). It uses this package, as do `just store …` and a catalog's CI. All three run the same checks, so an item that passes the catalog's CI installs in the editor.

## Install

In a Just Game Engine project:

```text
flutter pub add --dev just_asset_store
```

`just` then finds the store's commands among the project's packages, and runs them with `dart run just_asset_store:just_plugin`, so a project always uses the store version it locked.

## Platforms

- **`package:just_asset_store/just_asset_store.dart` runs on every platform Dart does**: Windows, macOS, Linux, Android, iOS, and the web, compiled to JavaScript or WebAssembly. Everywhere it reads catalogs (`StoreIndex`) and item manifests (`ItemManifest`), checks a package's archive in memory (`PackageCheck`), reads and writes the lockfile (`StoreLock`), and writes the generated registries' text (`StoreCodegen`).
- **Where `dart:io` is** (every platform but the web), the same library also holds the store on disk: `AssetStore` with its sources, downloads, planner and installer, restoring and linking, the creator tools and the `just store` commands.

## Every store item is a package

| Kind | Installs as |
|---|---|
| `content`: art, sound, tilesets… | An asset-only package in `packages/{category}/{id}/`. Its assets are `packages/<id>/...`: the same key in the editor and the game, never rewritten. |
| `editor-extension` | A plugin in `plugins/{category}/{id}/`, under `dev_dependencies`, so release builds leave out its native plugins. Its modules go into the generated `lib/editor/store_modules.g.dart`. |
| `kit`: game code plus an editor part | A plugin in `plugins/{category}/{id}/`, as a regular dependency. Its modules are registered as above, and its runtime `ContextExtension`s go into `lib/game/store_extensions.g.dart`. |
| `runtime-library` | A hosted pub.dev dependency. Nothing is copied. |
| `template`: a whole project to start from | Never installed. `just store template <id>` (or `just create <folder> --template <id>`) lays its `template/` folder over a project and installs what it needs. |

Items that are only on GitHub depend on each other by version. The store writes a marked `dependency_overrides` block that points each one at its installed copy. Overrides skip pub's version checks, so the store checks every constraint itself before it changes anything: it picks the newest versions that fit together, going back on a choice when it has to, never downgrades on an update, and keeps what is installed while it still fits.

Installing an item that is already there as another item's dependency makes it one of the project's own, so it stays when that item goes. Uninstalling takes the dependencies nothing else needs, unless the project's own code imports one.

**Trust.** Only the official catalog says which items the store vouches for. Every other catalog's items are community items: before code from one is installed, the store says that it runs with the user's permissions. Code straight from a GitHub repository that no catalog lists is installed only after a warning, and never by `--yes` alone.

## Installing is all or nothing

Every archive is downloaded and checked before the project is touched:
- **The pin:** its SHA-256 and size must match the catalog.
- **The zip:** no zip-slip, symlinks, ZIP64 or bombs, and no names that clash on Windows.
- **The package:** its manifest and pubspec must agree with the catalog. Only allowed file types. No build hooks or platform folders, in any letter case. Dependencies only by version from pub.dev, or on an SDK: no path, git or other package server. Every library its manifest registers must be in it. Content assets must sit where Flutter ships them.

Then, with a journal written ahead of each step, the store:
1. backs up every file it will change
2. stages the new folders and swaps them in
3. edits only its own marked blocks in the pubspec files, keeping comments, BOM and each line's ending
4. runs `dart pub get`
5. regenerates the registry files (only those the project can compile: `store_modules.g.dart` needs `just_game_engine_editor`, `store_extensions.g.dart` needs `just_game_engine`)
6. writes `just_store.lock.json`

If any step fails, everything is put back byte for byte. A crash part-way is rolled back the next time the store runs. Every command that changes the project — installs, `restore`, `link`, `sources`, `generate` — holds the project's lock, so one change runs at a time.

## `just store`

The store has no command-line tool of its own: its commands are a plugin of the `just` tool (just_core_cli). `just add` and `just remove` are shortcuts for `just store install` and `just store uninstall`, and `just check` and `just doctor` run `just store generate --check`.

```text
just store install <id>[@<version>]       # or https://github.com/<owner>/<repo>[@<tag>] [--unlisted]
just store update [<id>]
just store uninstall <id>
just store list
just store search [<words>]
just store info <id>
just store restore                        # folders missing after a clone
just store generate [--check]             # --check for CI
just store link <folder>... | unlink <id> | vendor <id>...
just store sources [add <url> | remove <id|url>]
just store cache [clean]
just store template <id>[@<version>] [--overwrite]

just store validate <folder|zip>
just store pack <folder> -o <out> --url <release download url> [--tag <tag>]
just store index build <catalog repo> -o site
just store index check <catalog repo> [--download [--only <id>]]
just store index codeowners <catalog repo> [--file .github/CODEOWNERS]
```

Every command has its own `--help`, and takes `--json`, `--yes`, `--verbose` and `--project <folder>`. Relative paths are read from the folder you are in.

Outside a project (a catalog's or an item's CI), activate the store globally and run its commands directly, at a pinned version:

```text
dart pub global activate just_asset_store 0.1.0
dart pub global run just_asset_store:just_plugin store index check .
```

The [repository](https://github.com/just-unknown-dev/just-asset-store/tree/main/templates) holds two templates to copy: `templates/catalog`, a catalog repository (GitHub Pages publishing, pull-request validation, CODEOWNERS), and `templates/item`, an item repository with a release workflow. They are not in the pub.dev package.

## The library

On a machine, the store does what `just store` does for a project on disk:

```dart
import 'package:just_asset_store/just_asset_store.dart';

Future<void> main() async {
  final store = AssetStore(
    project: StoreProject('.'),
    cacheDir: StorePaths.defaultCacheDir(),
  );
  final loaded = await store.loadCatalog();
  final plan = (await store.planner(catalog: loaded.catalog))
      .install('just_art_knight');
  // Show plan.changes and plan.issues; then:
  if (plan.canApply) {
    await store.installer().apply(plan, onProgress: print);
  }
}
```

Everywhere, the web included, it reads catalogs and checks packages in memory: see the [example](example/just_asset_store_example.dart), which pins an archive, runs every package check on it, and records it in a lockfile.

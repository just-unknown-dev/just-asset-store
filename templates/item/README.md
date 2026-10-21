# A Just Asset Store item

Every store item is a Dart package. Copy this folder into a new GitHub repository to make one: it is a content item (one sprite) that already validates and packs, for you to replace with your own.

## What a package holds

- **`pubspec.yaml`**: `name` is the item id, `version` the item version.
  - Ids are lowercase letters, digits and `_`. Ids starting `just_` belong to the Just Game Engine's own packages.
  - A content item lists every asset folder under `flutter: assets:`. Flutter doesn't look into subfolders, so list each one.
  - Code items depend on other store items by version, for example `just_game_engine_editor: ^0.1.0`, never by `path:` or `git:`, and only on packages from pub.dev otherwise. The store points store items at their installed copies.
- **`just_store.json`** describes the item to the store:

  | Field | What it holds |
  |---|---|
  | `schema` | `1`. |
  | `id`, `name`, `version`, `kind`, `category` | `kind` is `content`, `editor-extension`, `kit`, or `template` (a whole project to start from: its files go in `template/`). |
  | `license` | An SPDX id, plus `attribution` when users must credit you. |
  | `requires` | What it needs of the project: `sdk` (Dart), `flutter`, `just_game_engine`, `just_game_engine_editor`, each a version constraint. |
  | `dependencies` | The other store items it needs, by id, each a version constraint. Each must also be in the pubspec's `dependencies`, and the catalog must list the same. |
  | `content.assetFolders` | The same list as the pubspec. |
  | `content.entryPoints` | Its main files, each `{kind, path}`, for the details pane. |
  | `editor.modules` | Each `{library, class, order}` editor module to register. The class needs a constructor with no arguments, and the library must be in the package. |
  | `editor.editorOnlyLibraries` | `["*"]` for an editor extension. For a kit, its editor libraries, for example `["editor.dart", "src/editor/"]`. |
  | `runtime.extensions` | Each `{library, const, order}` engine extension, for example `MyKit.extension`. |
  | `runtime.componentTypes` | The component types it adds. Uninstalling uses this to find the scenes that use them. |
  | `runtime.setup` | `file`, where hand-written wiring goes, and `snippet`, the wiring the store shows after installing, for things it can't generate. |
  | `previews` | Pictures for its details pane, inside the package; each must be there. |
- **`CHANGELOG.md`**, with a `## <version>` section for each release: the release workflow posts it as the release's notes.
- **The files**, inside the package:
  - Refer to your own files as `packages/<id>/...`: a tileset's `image`, a map's `tilesets`, an animator's `atlas`.
  - Paths relative to their own file are fine too: an atlas's `meta.image`, and Tiled references.

## What a package must not hold

- Platform folders (`android/`, `ios/`, `windows/`…) or build hooks (`hook/`), in any letter case: no native code of its own. A code item may depend on a Flutter plugin package; the store tells users when one brings native code into their game.
- Scripts or binaries (`bin/`, `tool/`), hidden folders, a `pubspec.lock` or `pubspec_overrides.yaml`.

Content items also hold no Dart code, and depend on nothing.

## Releasing

1. Check it: `just store validate .`
2. Push a tag `v<version>`. The release workflow:
   - checks that the tag matches the pubspec's version
   - packs the package: the same bytes on any OS, with text files in LF
   - creates the Release, with three files: the archive `<id>-<version>.zip`, the catalog's version file `<id>-<version>.json`, and `just_release.json`
3. List it:
   - **In the Just Asset Store:** submit the repository once at [store.justunknown.com](https://store.justunknown.com); later releases are found from their `just_release.json`.
   - **In a catalog of your own** (the repository's `templates/catalog`): add the version file as `items/<id>/versions/<version>.json` in a pull request; the first release also needs `items/<id>/item.json`.
   - **Unlisted:** anyone can install it straight from the repository with `just store install https://github.com/<owner>/<repo>`, after being told nobody reviewed it.

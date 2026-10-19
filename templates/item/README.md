# A Just Asset Store item

Every store item is a Dart package. Copy this folder into a new GitHub repository to make one.

## What a package holds

- **`pubspec.yaml`**: `name` is the item id, which must be unique on pub.dev too. `version` is the item version.
  - A content item lists every asset folder under `flutter: assets:`. Flutter doesn't look into subfolders, so list each one.
  - Code items depend on store items by version, for example `just_game_engine_editor: ^0.1.0-dev.1`, never by `path:` or `git:`. The store points those dependencies at the installed copies.
- **`just_store.json`** describes the item to the store:

  | Field | What it holds |
  |---|---|
  | `id`, `name`, `version`, `kind`, `category` | `kind` is `content`, `editor-extension` or `kit`. |
  | `license` | An SPDX id, plus `attribution` when users must credit you. |
  | `content.assetFolders` | The same list as the pubspec. |
  | `editor.modules` | Each `{library, class}` editor module to register. The class needs a constructor with no arguments. |
  | `editor.editorOnlyLibraries` | `["*"]` for an editor extension. For a kit, its editor libraries, for example `["editor.dart", "src/editor/"]`. |
  | `runtime.extensions` | Each `{library, const}` engine extension, for example `MyKit.extension`. |
  | `runtime.componentTypes` | The component types it adds. Uninstalling uses this to find the scenes that use them. |
  | `runtime.setup.snippet` | Hand-written wiring the store shows after installing, for things it can't generate. |
- **The files**, inside the package:
  - Refer to your own files as `packages/<id>/...`: a tileset's `image`, a map's `tilesets`, an animator's `atlas`.
  - Paths relative to their own file are fine too: an atlas's `meta.image`, and Tiled references.

## What a package must not hold

- Native code or platform folders (`windows/`, `android/`…)
- Build hooks (`hook/`), scripts or binaries
- Hidden folders
- A `pubspec.lock`

Content items also hold no Dart code.

## Releasing

1. Check it: `just store validate .`
2. Push a tag `v<version>`. The release workflow:
   - packs the package; the same bytes on any OS, with text files in LF
   - attaches the archive and `<id>-<version>.json` to a GitHub Release
3. Copy the version file into the catalog repository as `items/<id>/versions/<version>.json`, in a pull request. The first release also needs `items/<id>/item.json`.

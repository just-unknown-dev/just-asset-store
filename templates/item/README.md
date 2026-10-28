# A Just Asset Store item

Every store item is a Dart package. Copy this folder into a new GitHub repository to make one: it is a content item (one sprite) that already validates and packs, for you to replace with your own.

> **The store's first version lists only Just Unknown's own packages.** Publishing opens to everyone in a later version. Until then you can still build, validate and pack a package with this template, and share it from a catalog of your own (`templates/catalog`).

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
  | `summary`, `description`, `tags`, `author` | What the store shows: one line for its card, a longer text, search words, and `{name, url}`. |
  | `permissions` | For code items, what its code does that users should know first: `network`, `files` (outside the project), `processes`, `native`. Shown before every install. Declare `native` when any package it gets from pub.dev brings native code (a Flutter plugin, or build hooks), however indirectly: the store looks, and refuses a release that brings native code without it. What the project has anyway through `requires` and `dependencies` doesn't count. |
  | `stage` | How finished this version is: `stable`, `beta`, `experimental` or `deprecated`. Every editor tool and kit names one (`pack` and `validate` refuse one without). The store and the editor show it; experimental items are listed only to those who turn on "Show experimental", deprecated ones only to a search, and installing either asks first. |
  | `replacedBy` | For a deprecated item: the id of the item that replaces it, which the store suggests. |
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
  | `previews` | Pictures for its store page, inside the package; the first is its card picture (16:9, 1280×720 works well). Up to 8 `.png`, `.jpg` or `.webp` files, each with a plain file name of its own (letters, digits, `.`, `_`, `+`, `-`): `just store pack` copies them beside the archive, and they go up as release files, which the store finds by name. |
- **`CHANGELOG.md`**, with a `## <version>` section for each release: the release workflow posts it as the release's notes.
- **The files**, inside the package:
  - Refer to your own files as `packages/<id>/...`: a tileset's `image`, a map's `tilesets`, an animator's `atlas`.
  - Paths relative to their own file are fine too: an atlas's `meta.image`, and Tiled references.

## What a package must not hold

- Platform folders (`android/`, `ios/`, `windows/`…) or build hooks (`hook/`), in any letter case: no native code of its own. A code item may depend on a Flutter plugin package, declaring `native`; the store tells users which ones it brings into their game.
- Scripts or binaries (`bin/`, `tool/`), hidden folders, a `pubspec.lock` or `pubspec_overrides.yaml`.

Content items also hold no Dart code, and depend on nothing.

## Choosing an id

An id is the package's name in every project that installs it, and the store points the whole project at its copy. So it can't be:

- `just`, or start with `just_`: those are the store's own team's.
- A Flutter SDK package (`flutter`, `flutter_test`…).
- The name of a package on pub.dev: projects that use that package would get yours instead. The store checks when you first submit.

## Releasing

Once, in the repository's settings:
- **Turn on release immutability** (Settings → General → Releases). The store lists only versions from immutable releases: once published, nobody — you included — can swap their files, so what users install is what the store checked.
- **Add your claim code** as the Actions variable `JUST_STORE_CLAIM` (Settings → Secrets and variables → Actions → Variables). The store's Publish page shows yours once you sign in; it says your store account may publish this package.

Then for each version:

1. Check it: `just store validate .`
2. Push a tag `v<version>`. The release workflow:
   - checks that the tag matches the pubspec's version
   - packs the package: the same bytes on any OS, with text files in LF
   - creates the Release, with three files: the archive `<id>-<version>.zip`, the catalog's version file `<id>-<version>.json`, and `just_release.json` (which carries your claim code)
3. List it:
   - **In the Just Asset Store:** submit the repository once at [asset.justunknown.com](https://asset.justunknown.com); later releases are found from their `just_release.json`.
   - **In a catalog of your own** (the repository's `templates/catalog`): add the version file as `items/<id>/versions/<version>.json` in a pull request; the first release also needs `items/<id>/item.json`.
   - **Unlisted:** anyone can install it straight from the repository with `just store install https://github.com/<owner>/<repo>`, after being told nobody reviewed it.

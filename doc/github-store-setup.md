# Setting up the Asset Store on GitHub

> **The catalog moved to Firebase.** The store's records now live in
> Firestore, written only by the backend's GitHub Actions, and the catalog and
> website are served from Firebase Hosting — see
> [just_asset_store_backend](../../just_asset_store_backend/README.md). What
> this guide says about **item repositories and their releases** (steps 0, 1
> and 3) still holds; the GitHub Pages catalog repository (steps 2, 4 and 5,
> `templates/catalog/`) is replaced by the backend: a package is submitted with
> an issue form, not a pull request, and new releases are found by the hourly
> refresh.

This guide puts the Just Asset Store online. You need nothing but GitHub: the catalog is static files on GitHub Pages, and each item's archive is a file on a GitHub Release.

Everything below assumes the GitHub organization **`just-unknown-dev`**. If you use another organization, or other repository names, change the names in the places listed under [Names baked into the code](#names-baked-into-the-code).

---

## How the pieces fit

```text
just-asset-store                  the store's core package and its `store` tool
just-asset-store-editor           the store window (an editor module)
just-game-engine-editor           ┐
just-sprite-editor                │ item repositories: one per store item.
just-input-editor                 │ Pushing a tag v1.2.0 builds the item's
just-ui-editor                    │ archive and attaches it to a Release.
just-platformer-kit               │
just-art-…  (art and sound)       ┘

just-asset-store-catalog          the catalog: one pull request per new version.
                                  Merging publishes index.json on GitHub Pages:
https://just-unknown-dev.github.io/just-asset-store-catalog/index.json
                                  which the editor's store reads.
```

The flow for every version of every item is the same:

1. Bump the version in the item's repository, push a tag, and its workflow makes a Release holding `<id>-<version>.zip` and `<id>-<version>.json`.
2. Copy that `.json` into the catalog as `items/<id>/versions/<version>.json`, and open a pull request.
3. The catalog's checks download the archive, compare it with its pinned SHA-256, and run the installer's own checks on it.
4. Merge. The catalog republishes, and every editor sees the new version.

The catalog never holds the archives, only their fingerprints. An archive that changes after its version file is merged is refused by every editor. So **never re-upload or replace a Release asset**: publish a new version instead.

---

## 0. Before you start

Publish these to pub.dev first, in this order:

1. **`just_deflate`, then `just_game_engine_formats`, then `just_core_cli`.** The store builds on just_core_cli (which needs the other two), and every workflow below installs `just` and the store, which resolve them from pub.dev.
2. **`just_game_engine` and its dependencies** (see the engine's release notes for the order). Items only need them once someone installs them: `pub get` in a user's project has to find them. Publish them before you announce the store, or move the template onto it (step 6).
3. **`just_audio_engine` 1.0.2.** It lets items ship sounds as `packages/<name>/…`.

On your machine you need:

- `git`
- the GitHub CLI, `gh`, logged in to the organization (`gh auth login`)
- the Dart SDK. The one inside Flutter is fine.

---

## 1. The store's own repository: `just-asset-store`

This holds `packages/just_asset_store`: the core library, the `store` command-line tool, and the two templates this guide uses (`templates/catalog`, `templates/item`).

1. Make `packages/just_asset_store` a repository and push it:

   ```bash
   cd packages/just_asset_store
   git init -b main
   git add -A
   git commit -m "just_asset_store 0.1.0"
   gh repo create just-unknown-dev/just-asset-store --public --source . --push
   ```

   `pubspec_overrides.yaml` is git-ignored, so the local path override doesn't leave your machine. The test fixtures are marked `-text` in `.gitattributes`, so git keeps their line endings exactly.

2. Check that the tool installs from GitHub, the way every workflow will install it:

   ```bash
   dart pub global activate just_core_cli
   dart pub global activate --source git https://github.com/just-unknown-dev/just-asset-store
   just store --help
   ```

   The store has no tool of its own: `just` (from just_core_cli) runs its commands. If this fails on `just_core_cli`, `just_game_engine_formats` or `just_deflate`, that package isn't on pub.dev yet (see step 0).

3. Add the item release workflow (step 3 explains it), so the store core can be a store item too:

   ```bash
   mkdir -p .github/workflows
   cp templates/item/.github/workflows/release.yml .github/workflows/
   git add -A && git commit -m "Release workflow" && git push
   ```

> The core is an item because the store window depends on it. When someone installs the window from the catalog, the store fetches the core too. Its manifest marks it `system`, so it can't be uninstalled. Official items may ship a `bin/` folder; nobody else's may.

---

## 2. The catalog repository: `just-asset-store-catalog`

### Create it

```bash
cp -r packages/just_asset_store/templates/catalog ../just-asset-store-catalog
cd ../just-asset-store-catalog
git init -b main
git add -A
git commit -m "The catalog"
gh repo create just-unknown-dev/just-asset-store-catalog --public --source . --push
```

What the template holds:

| File | What it is |
|---|---|
| `catalog.json` | The source's id (`just-official`) and name, the categories, and the maintainers. The maintainers own every file, through CODEOWNERS. |
| `publishers/just.json` | You, as the `official` publisher. `github` lists the handles allowed to change your items. |
| `items/` | One folder per item (step 4). Empty for now. |
| `.github/workflows/validate.yml` | Runs on every pull request: the catalog builds, each changed item's archive downloads and passes the checks, and CODEOWNERS is current. |
| `.github/workflows/publish.yml` | Runs on every merge to `main`: builds `index.json` and the pictures, and deploys them to GitHub Pages. |
| `.github/CODEOWNERS` | Generated: who may approve changes where. |
| `.github/PULL_REQUEST_TEMPLATE.md` | The checklist every submission answers. |

Check the handles in `catalog.json` (`maintainers`) and `publishers/just.json` (`github`). They should be your GitHub username(s).

### Turn on GitHub Pages

1. Go to **Settings → Pages → Build and deployment → Source**, and choose **GitHub Actions**.
2. Go to **Actions**, open **Publish**, and click **Run workflow**. (Any later merge to `main` runs it too.)
3. Open `https://just-unknown-dev.github.io/just-asset-store-catalog/index.json`. You should see a catalog with no items.

### Protect `main`

Go to **Settings → Rules → Rulesets → New branch ruleset** (or **Settings → Branches → Add rule**). Target `main` and turn on:

- **Require a pull request before merging.**
  - Turn on **Require review from Code Owners** too.
  - While you are the only maintainer, add yourself to the bypass list, or set the required approvals to 0. Otherwise you can't merge your own pull requests.
- **Require status checks to pass:** add **validate**, the job in `validate.yml`.
- **Block force pushes.**

---

## 3. An item's repository

Every store item is a Dart package in a repository of its own, with the package at the repository's root.

### What it needs

- **`pubspec.yaml`**:
  - `name` is the item id.
  - `version` is the item's version.
  - It depends on other items by version, never by `path:` or `git:`. For example, `just_game_engine_editor: ^0.1.0-dev.1`.
- **`just_store.json`**, the item's manifest. The first-party packages already have one; for a new item, copy `templates/item/just_store.json`. Its `version` must equal the pubspec's.
- **`CHANGELOG.md`**. The release workflow uses it as the release notes.
- **`LICENSE`**. Recommended. Put the same licence in the manifest and the catalog entry, as an SPDX id like `MIT`, `BSD-3-Clause` or `CC0-1.0`.
- **`.github/workflows/release.yml`**, copied from `templates/item/.github/workflows/release.yml`.

### The first-party items

| Package folder | Repository | Item id | Category | Kind |
|---|---|---|---|---|
| `packages/just_asset_store` | `just-asset-store` | `just_asset_store` | `core` | editor-extension, system |
| `packages/just_asset_store_editor` | `just-asset-store-editor` | `just_asset_store_editor` | `core` | editor-extension, system |
| `packages/just_game_engine_editor` | `just-game-engine-editor` | `just_game_engine_editor` | `core` | editor-extension, system |
| `packages/just_sprite_editor` | `just-sprite-editor` | `just_sprite_editor` | `editors` | editor-extension |
| `packages/just_input_editor` | `just-input-editor` | `just_input_editor` | `editors` | editor-extension |
| `packages/just_ui_editor` | `just-ui-editor` | `just_ui_editor` | `kits` | kit |
| `packages/just_platformer_kit` | `just-platformer-kit` | `just_platformer_kit` | `kits` | kit |

If a package already has a repository, use it. Then add the workflow:

```bash
cd packages/just_sprite_editor        # each in turn
mkdir -p .github/workflows
cp ../just_asset_store/templates/item/.github/workflows/release.yml .github/workflows/
```

None of these packages has a licence yet; their manifests leave the `license` field out. Add a `LICENSE` and the `license` field before the first release if you want one shown in the store.

### Check it before you release

From the package's folder:

```bash
just store validate .
```

This packs the package exactly as the release will, and runs every check the installer runs. It also warns about paths that work in your project but break once the package is installed. Fix everything it reports.

### Release a version

1. Set the same version in `pubspec.yaml` and `just_store.json`, and add a `CHANGELOG.md` entry.
2. Commit, then tag and push:

   ```bash
   git tag v0.1.0
   git push origin main v0.1.0
   ```

3. The **Release** workflow:
   - checks the tag matches the pubspec's version
   - packs the package (the same bytes on any OS; text files get LF line endings)
   - creates the Release `v0.1.0`, with two files: `just_sprite_editor-0.1.0.zip`, the archive, and `just_sprite_editor-0.1.0.json`, the catalog's version file with its URL, SHA-256 and size

If the workflow can't create the release, go to **Settings → Actions → General → Workflow permissions** and allow **Read and write**. The workflow asks for `contents: write`.

### Art and sound items

A content item is a package with no code, only assets. Start from `templates/item`:

- **Every asset sits directly in an asset folder.** For example, `sprites/knight.png`, not `sprites/hero/knight.png`. Flutter does not look into subfolders.
- **The folders are listed twice:** in the pubspec's `flutter: assets:` and in the manifest's `content.assetFolders`, and the two lists must be identical.
- **Inside the package, files refer to each other** as `packages/<id>/…`. For example, a tileset's `"image": "packages/just_art_forest/tiles/forest.png"`. An atlas's `meta.image` can stay relative to the atlas.
- **No `dependencies`, no plugins, no Dart code.**

---

## 4. List a version in the catalog

### A new item

Make a folder named after the item id:

```text
items/just_sprite_editor/
  item.json                     what the store shows (below)
  versions/0.1.0.json           the release's .json, renamed
  thumbnail.png                 its card picture, at most 512 KB (optional)
  previews/1.png …              pictures for its details pane (optional)
```

`item.json` for code:

```json
{
  "id": "just_sprite_editor",
  "name": "Sprite Studio",
  "kind": "editor-extension",
  "category": "editors",
  "summary": "A pixel-art sprite editor and animator, inside the editor.",
  "description": "Layers, frames, tags, onion skin and an animation state-machine graph. Saves sheets and atlases the engine plays.",
  "tags": ["sprites", "pixel art", "animation"],
  "author": {"name": "Just", "url": "https://github.com/just-unknown-dev"},
  "publisher": "just",
  "sourceRepo": "https://github.com/just-unknown-dev/just-sprite-editor"
}
```

`item.json` for art:

```json
{
  "id": "just_art_knight",
  "name": "Knight",
  "kind": "content",
  "category": "characters",
  "summary": "A pixel knight with idle, run, jump and attack clips.",
  "tags": ["pixel art", "hero", "16x16"],
  "author": {"name": "Just"},
  "license": {"spdx": "CC-BY-4.0", "attribution": "Knight by Just (CC BY 4.0)"},
  "publisher": "just"
}
```

What the fields mean:

| Field | What it is |
|---|---|
| `id` | Equals the folder name and the package name. Lowercase letters, digits and `_`. It must not be taken on pub.dev. |
| `kind` | `content`, `editor-extension`, `kit` or `runtime-library`. It must match the manifest. |
| `category` | One of `catalog.json`'s category ids, and it must match the manifest. It is also the folder the item installs into: `packages/<category>/<id>/`. |
| `license.attribution` | Shown to everyone who installs the item. Use it whenever the licence asks for credit. |
| `trust` | Don't write it. Trust comes from the publisher's file. |

**Version files.** Use the release's `.json` as it is. It already has the URL, `sha256` and size, plus `requires` and `dependencies` from the manifest. Add these yourself when they apply:

- `"nativePlugins": ["file_selector"]` when the package brings Flutter plugins with native code. `just_sprite_editor` does. The store warns about them before installing.
- `"notes": "What changed"`, shown in the details pane.

### A library from pub.dev

Runtime-only libraries stay on pub.dev; the catalog only lists them. There is no archive and no release.

`items/just_tiled/item.json`:

```json
{"id": "just_tiled", "name": "Tiled maps", "kind": "runtime-library",
 "category": "libraries", "pub": {"package": "just_tiled"},
 "summary": "Load Tiled maps and tilesets."}
```

`items/just_tiled/versions/0.4.1.json`:

```json
{"version": "0.4.1", "constraint": "^0.4.1"}
```

Installing it adds `just_tiled: ^0.4.1` to the project's dependencies.

### Regenerate CODEOWNERS, check, open the pull request

```bash
cd just-asset-store-catalog
just store index codeowners . > .github/CODEOWNERS
just store index check . --download
git checkout -b add-just-sprite-editor-0.1.0
git add -A && git commit -m "just_sprite_editor 0.1.0"
git push -u origin HEAD
gh pr create --fill
```

`index check --download` runs the same checks as the pull request workflow. Merge when **validate** is green. **Publish** then puts the new `index.json` live within a minute or two.

> **Release items in dependency order.** An item whose `dependencies` aren't in the catalog can't be installed, and the store says so. Release and list `just_game_engine_editor` and `just_asset_store` first, then the rest.

---

## 5. Try it

**Before merging**, preview the catalog from your machine:

```bash
just store index build . -o site
```

Then do either of these:

- In the editor, go to **Asset Store → Sources**, paste the full path of the `site` folder, and click **Add**.
- From a scratch project:

  ```bash
  just store install just_art_knight --source <path>/site --project <scratch project>
  ```

A local catalog downloads its archives from GitHub Releases, as the real one does.

**After merging**, the editor reads the official catalog by itself. Open the store (the shop button, or Ctrl+Shift+G) and click **Check the catalogs again** in its header.

**On macOS**, the editor needs the network permission in `macos/Runner/DebugProfile.entitlements`. The template has it. Other projects add:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

---

## 6. Move the template onto the store

In this repository the template's own packages are **linked**: `just_store.lock.json` points at your checkouts in `packages/<name>/`, and the git-ignored `pubspec_overrides.yaml` tells pub to use them. That stays the same for development.

A copy of the template that you share must work without your checkouts. Once the first-party items are in the catalog, and the engine is on pub.dev, convert a fresh clone:

1. Clone the template somewhere new. It has no `packages/` checkouts and no `pubspec_overrides.yaml`.
2. In its `pubspec.yaml`, delete the hand-written entries:
   - under `dependencies`: `just_game_engine_editor`, `just_sprite_editor`, `just_input_editor`, `just_ui_editor`, `just_platformer_kit` and `just_asset_store_editor`
   - under `dev_dependencies`: `just_asset_store`

   The store will write its own entries for them.
3. Delete `just_store.lock.json`. Its entries point at checkouts that this clone doesn't have.
4. Install the first-party items from the catalog, in this order:

   ```bash
   for id in just_game_engine_editor just_asset_store_editor just_platformer_kit \
             just_ui_editor just_sprite_editor just_input_editor; do
     just store install $id --project . -y
   done
   ```

   Each install puts the package in `packages/<category>/<id>/` and adds it to the store's marked blocks in `pubspec.yaml`. It also records the archive's URL and fingerprint, and regenerates `lib/editor/store_modules.g.dart` and `lib/game/store_extensions.g.dart`. `main_editor.dart` and `GameBoot` already use those generated lists.
5. Check it:
   - `just store list` shows the six items.
   - `dart run tool/check_release_imports.dart` prints **OK**.
   - `flutter run -t lib/main_editor.dart -d windows` opens the editor with every tool.
6. Commit it, in one of two ways:
   - **Commit `packages/`**, so a clone works offline at once.
   - **Leave `packages/` out of git.** Each clone then runs `just store restore`, which downloads every item again, checked against the fingerprints in `just_store.lock.json`.

---

## Releasing a new version

1. In the item's repository: bump the version in `pubspec.yaml` and `just_store.json`, add a `CHANGELOG.md` entry, then commit, tag `v<version>` and push.
2. In the catalog: add `items/<id>/versions/<version>.json` from the release, then open a pull request and merge it.
3. Projects that have the item see **Update** in the store, and in its **Updates** page.

To take a version back, set `"yanked": true` in its version file. New installs skip it, and projects that already have it keep it.

For a licence or safety problem, set `"blocked": true` instead. The editor then flags it in the Problems dock of every project that has it installed.

Never delete a version file that projects may have installed, and never replace its Release asset.

---

## Community publishers (later)

The catalog is already built for more than one publisher:

1. Add `publishers/<their-id>.json`:

   ```json
   {"id": "pixel_folk", "name": "Pixel Folk", "github": ["their-handle"], "trust": "community"}
   ```

2. They publish from their own repositories, with the same item template and release workflow. They add `items/<id>/` with `"publisher": "pixel_folk"` and open a pull request.
3. Regenerate CODEOWNERS. Their `items/<id>/` folders then belong to them (and the maintainers).
4. Review:
   - **Content:** the automatic checks do most of the work.
   - **Code:** read every version, and require a public `sourceRepo`.

   A publisher who has earned it can move to `"trust": "verified"`.

## Paid items (later)

Paid items need one small server: a download broker that checks the buyer and hands out a short-lived link. The catalog lists a paid item as usual, with two differences:

- **The item** has `"pricing": {"model": "paid", "amount": 499, "currency": "USD", "licence": "per-seat"}`.
- **Its versions** have `"access": "entitled"` and `"download": {"broker": "https://…"}` instead of an archive URL. The SHA-256 pin stays.

Until the broker exists, the editor shows such items but won't install them.

---

## Names baked into the code

If you choose other names, change them here:

| Name | Where |
|---|---|
| Catalog URL `https://just-unknown-dev.github.io/just-asset-store-catalog/index.json` | `packages/just_asset_store/lib/src/sources/store_source.dart`, `SourceConfig.official` |
| Store tool repository `https://github.com/just-unknown-dev/just-asset-store` | the three workflows in `templates/` (`validate.yml`, `publish.yml`, `release.yml`), and `packages/just_asset_store/pubspec.yaml` |
| Catalog homepage | `templates/catalog/catalog.json` → `source.homepage` |
| Maintainers and the official publisher's handles | `templates/catalog/catalog.json` → `maintainers`, `templates/catalog/publishers/just.json` → `github` |

---

## When something goes wrong

| What you see | What it means |
|---|---|
| Release workflow: "Tag v1.2.0 but pubspec says 1.1.0" | The tag must equal `v` plus the pubspec's version. |
| Validate: "does not match its catalog fingerprint (SHA-256)" | The Release asset changed after its version file was written. Release a new version instead. |
| Validate: "No version of X fits" or "is not in any of your sources" | A dependency isn't in the catalog yet, or no listed version fits. Release and list it first. |
| Validate: "… is not directly in an asset folder, so it would not ship" | Move the file up into a listed folder, or list its folder in both the pubspec and the manifest. |
| Validate: "CODEOWNERS" diff | Run `just store index codeowners . > .github/CODEOWNERS` and commit it. |
| The editor shows "Offline: showing the … catalog as last downloaded" | Pages couldn't be reached. The store keeps working from its cached copy. |
| The editor shows "Could not read Just Asset Store" | Pages isn't live yet, or the URL in `SourceConfig.official` doesn't match the catalog repository's name. |
| macOS: "macOS blocked the connection" | Add the network permission (step 5). |
| Install: "pub get failed … version solving failed" | A dependency isn't on pub.dev yet (step 0). Nothing was changed in the project. |

# Store items and catalogs on GitHub

How the Just Asset Store's items are made and released, and how to run a catalog of your own on GitHub Pages.

**The official catalog** is not a repository you edit. Its records are in Firestore, written only by the backend's GitHub Actions in the website's repository (`packages/just_asset_store_backend`), and it is served with the website from Firebase Hosting, at `https://store.justunknown.com/index.json` — the address `SourceConfig.official` reads. A package gets in by being submitted on the website once; its later releases are found by the backend's hourly refresh, from the `just_release.json` every release carries.

Everything below assumes the GitHub organization **`just-unknown-dev`**. If you use another organization, or other names, change them in the places listed under [Names baked into the code](#names-baked-into-the-code).

---

## How the pieces fit

```text
just-asset-store                  the store's core (just_asset_store, on
                                  pub.dev), with `just store …` and the two
                                  templates below
the website's repository          the website and the backend
just-asset-store-editor           the store window (an editor module)
just-game-engine-editor           ┐
just-sprite-editor                │ item repositories: one per store item.
just-platformer-kit               │ Pushing a tag v1.2.0 builds the item's
just-art-…  (art and sound)       ┘ archive and attaches it to a Release.

a catalog of your own (optional)  templates/catalog: one pull request per new
                                  version; merging publishes index.json on
                                  GitHub Pages.
```

The flow for every version of every item is the same:

1. Bump the version in the item's repository, push a tag, and its workflow makes a Release holding `<id>-<version>.zip`, `<id>-<version>.json` (the catalog's version file) and `just_release.json`.
2. The official catalog finds it by itself; a catalog of your own gets the version file in a pull request.
3. Before it is listed, the archive is downloaded, compared with its pinned SHA-256, and put through the installer's own checks.

A catalog never holds the archives, only their fingerprints. An archive that changes after it was listed is refused by every project. So **never re-upload or replace a Release asset**: publish a new version instead.

---

## 0. The tools

On your machine:

- `git`, and the GitHub CLI `gh`, logged in (`gh auth login`)
- the Dart SDK (the one inside Flutter is fine)
- the store's commands:

  ```bash
  dart pub global activate just_core_cli
  dart pub global activate just_asset_store
  just store --help
  ```

  The store has no tool of its own: `just` (from just_core_cli) runs its commands. Where `just` isn't wanted — in CI, say — run them directly: `dart pub global run just_asset_store:just_plugin store --help`.

---

## 1. An item's repository

Every store item is a Dart package in a repository of its own, with the package at the repository's root. Start from `templates/item` in the `just-asset-store` repository: copy it, `.github/` included, into the new repository.

### What it needs

- **`pubspec.yaml`**:
  - `name` is the item id: lowercase letters, digits and `_`. Ids starting `just_` belong to the official packages.
  - `version` is the item's version.
  - It depends on other items by version, never by `path:` or `git:` — for example `just_game_engine_editor: ^0.1.0` — and otherwise only on packages from pub.dev.
- **`just_store.json`**, the item's manifest. Its `version` equals the pubspec's, and its `dependencies` list every store item the pubspec depends on: the store installs exactly those, and pub would look on pub.dev for any other.
- **`CHANGELOG.md`**, with a `## <version>` section per release: the release workflow posts it as the release notes.
- **`LICENSE`**, and the same licence in the manifest's `license` field as an SPDX id (`MIT`, `BSD-3-Clause`, `CC0-1.0`…), so the store can show it.
- **`.github/workflows/release.yml`**, from the template.

### Check it before you release

From the package's folder:

```bash
just store validate .
```

This packs the package exactly as the release will, and runs every check the installer runs. It also warns about paths that work in your project but break once the package is installed. Fix everything it reports.

### Release a version

1. Set the same version in `pubspec.yaml` and `just_store.json`, and add its `CHANGELOG.md` section.
2. Commit, then tag and push:

   ```bash
   git tag v0.1.0
   git push origin main v0.1.0
   ```

3. The **Release** workflow:
   - checks the tag matches the pubspec's version
   - packs the package (the same bytes on any OS; text files get LF line endings)
   - creates the Release `v0.1.0` with three files: the archive `<id>-0.1.0.zip`, the catalog's version file `<id>-0.1.0.json` (its URL, SHA-256 and size), and `just_release.json`

If the workflow can't create the release, go to **Settings → Actions → General → Workflow permissions** and allow **Read and write**. The workflow asks for `contents: write`.

### Art and sound items

A content item is a package with no code, only assets:

- **Every asset sits directly in an asset folder.** For example, `sprites/knight.png`, not `sprites/hero/knight.png`. Flutter does not look into subfolders.
- **The folders are listed twice:** in the pubspec's `flutter: assets:` and in the manifest's `content.assetFolders`, and the two lists must be identical.
- **Inside the package, files refer to each other** as `packages/<id>/…`. For example, a tileset's `"image": "packages/just_art_forest/tiles/forest.png"`. An atlas's `meta.image` can stay relative to the atlas.
- **No `dependencies`, no plugins, no Dart code.**

---

## 2. A catalog of your own

A studio's own catalog, or one for a community: static files on GitHub Pages, which projects add as a source. Its items are shown as community items, whatever its publishers' files say: the store vouches only for what its official catalog lists.

### Create it

```bash
git clone https://github.com/just-unknown-dev/just-asset-store
cp -r just-asset-store/templates/catalog ../my-catalog
cd ../my-catalog
git init -b main
git add -A
git commit -m "The catalog"
gh repo create <owner>/my-catalog --public --source . --push
```

What the template holds:

| File | What it is |
|---|---|
| `catalog.json` | The source's id and name, the categories, and the maintainers. The maintainers own every file, through CODEOWNERS. |
| `publishers/your_name.json` | A publisher: its name, the GitHub handles allowed to change its items, and its trust. Rename it; its `id` is the file's name. |
| `items/` | One folder per item. Empty for now. |
| `.github/workflows/validate.yml` | Runs on every pull request: the catalog builds, each changed item's archive downloads and passes the checks, and CODEOWNERS is current. |
| `.github/workflows/publish.yml` | Runs on every merge to `main`: builds `index.json` and the pictures, and deploys them to GitHub Pages. |
| `.github/CODEOWNERS` | Generated: who may approve changes where. |
| `.github/PULL_REQUEST_TEMPLATE.md` | The checklist every submission answers. |

Put your GitHub handle in `catalog.json` (`maintainers`) and the publisher's file (`github`).

### Turn on GitHub Pages

1. Go to **Settings → Pages → Build and deployment → Source**, and choose **GitHub Actions**.
2. Go to **Actions**, open **Publish**, and click **Run workflow**. (Any later merge to `main` runs it too.)
3. Open `https://<owner>.github.io/my-catalog/index.json`. You should see a catalog with no items.

### Protect `main`

Go to **Settings → Rules → Rulesets → New branch ruleset**. Target `main` and turn on:

- **Require a pull request before merging**, with **Require review from Code Owners**. While you are the only maintainer, add yourself to the bypass list, or set the required approvals to 0.
- **Require status checks to pass:** add **validate**, the job in `validate.yml`.
- **Block force pushes.**

### List a version

Make a folder named after the item id:

```text
items/my_sprite_tool/
  item.json                     what the store shows (below)
  versions/0.1.0.json           the release's <id>-0.1.0.json, renamed
  thumbnail.png                 its card picture, at most 512 KB (optional)
  previews/1.png …              pictures for its details pane (optional)
```

`item.json`:

```json
{
  "id": "my_sprite_tool",
  "name": "Sprite Tool",
  "kind": "editor-extension",
  "category": "editors",
  "summary": "A pixel-art sprite editor, inside the editor.",
  "tags": ["sprites", "pixel art"],
  "author": {"name": "Your name", "url": "https://github.com/<owner>"},
  "license": {"spdx": "MIT"},
  "publisher": "your_name",
  "sourceRepo": "https://github.com/<owner>/my-sprite-tool"
}
```

| Field | What it is |
|---|---|
| `id` | Equals the folder name and the package name. |
| `kind` | `content`, `editor-extension`, `kit`, `runtime-library` or `template`. It must match the manifest. |
| `category` | One of `catalog.json`'s category ids, and it must match the manifest. It is also the folder the item installs into: `packages/<category>/<id>/`. |
| `license.attribution` | Shown to everyone who installs the item. Use it whenever the licence asks for credit. |
| `trust` | Don't write it. Trust comes from the publisher's file. |

**Version files.** Use the release's `.json` as it is: it has the URL, `sha256` and size, plus `requires` and `dependencies` from the manifest, which must stay equal to the manifest's. Add these yourself when they apply:

- `"nativePlugins": ["file_selector"]` when the package brings Flutter plugins with native code. The store warns about them before installing.
- `"notes": "What changed"`, shown in the details pane.

**A library from pub.dev** stays on pub.dev; the catalog only lists it, with no archive. Its `item.json` has `"kind": "runtime-library"` and `"pub": {"package": "<id>"}` (its id is its pub.dev name), and each version file is `{"version": "0.4.1", "constraint": "^0.4.1"}`: installing it adds that constraint to the project's dependencies.

Then regenerate CODEOWNERS, check, and open the pull request:

```bash
just store index codeowners . --file .github/CODEOWNERS
just store index check . --download
git checkout -b add-my-sprite-tool-0.1.0
git add -A && git commit -m "my_sprite_tool 0.1.0"
git push -u origin HEAD
gh pr create --fill
```

`index check --download` runs the same checks as the pull request workflow. Merge when **validate** is green; **Publish** then puts the new `index.json` live within a minute or two.

> **List items in dependency order.** An item whose `dependencies` aren't in a project's sources can't be installed, and the store says so.

### Try it

**Before merging**, preview the catalog from your machine:

```bash
just store index build . -o site
```

Then, in the editor, go to **Asset Store → Sources**, paste the full path of the `site` folder, and click **Add**; or, from a scratch project:

```bash
just store install my_sprite_tool --source <path>/site --project <scratch project>
```

A local catalog downloads its archives from GitHub Releases, as the published one does.

**After merging**, add it to a project for good: `just store sources add https://<owner>.github.io/my-catalog/index.json`. The project keeps reading the official catalog too.

---

## 3. Moving the game template onto the store

In the template repository the first-party packages are **linked**: `just_store.lock.json` points at checkouts in `packages/<name>/`, and the git-ignored `pubspec_overrides.yaml` tells pub to use them. That stays the same for development.

A copy of the template that you share must work without the checkouts. Once the first-party items are in the official catalog, and the engine is on pub.dev, convert a fresh clone:

1. Clone the template somewhere new. It has no `packages/` checkouts and no `pubspec_overrides.yaml`.
2. In its `pubspec.yaml`, delete the hand-written entries for the store items (`just_game_engine_editor`, `just_sprite_editor`, `just_input_editor`, `just_ui_editor`, `just_platformer_kit`, `just_asset_store_editor`). The store writes its own entries for them.
3. Delete `just_store.lock.json`: its entries point at checkouts this clone doesn't have.
4. Install the first-party items:

   ```bash
   for id in just_game_engine_editor just_asset_store_editor just_platformer_kit \
             just_ui_editor just_sprite_editor just_input_editor; do
     just store install $id --project . -y
   done
   ```

   Each install puts the package in `packages/<category>/<id>/`, adds it to the store's marked blocks in `pubspec.yaml`, records the archive's URL and fingerprint, and regenerates `lib/editor/store_modules.g.dart` and `lib/game/store_extensions.g.dart`.
5. Check it: `just store list` shows the six items, and the editor opens with every tool.
6. Commit it, in one of two ways:
   - **Commit `packages/`**, so a clone works offline at once.
   - **Leave `packages/` out of git.** Each clone then runs `just store restore`, which downloads every item again, checked against the fingerprints in `just_store.lock.json`.

---

## Withdrawing a version

To take a version back, set `"yanked": true` in its version file. New installs skip it, and projects that already have it keep it.

For a licence or safety problem, set `"blocked": true` instead. Every project that has it installed is then warned by the store, in every plan and in `just store info`.

Never delete a version file that projects may have installed, and never replace its Release asset.

## More publishers

A catalog is built for more than one publisher:

1. Add `publishers/<their-id>.json`:

   ```json
   {"id": "pixel_folk", "name": "Pixel Folk", "github": ["their-handle"], "trust": "community"}
   ```

2. They publish from their own repositories, with the same item template and release workflow. They add `items/<id>/` with `"publisher": "pixel_folk"` and open a pull request.
3. Regenerate CODEOWNERS. Their `items/<id>/` folders then belong to them (and the maintainers); `publishers/` stays the maintainers' alone.
4. Review content lightly (the automatic checks do most of the work); read every version of code, and require a public `sourceRepo`.

## Paid items (later)

Paid items need one small server: a download broker that checks the buyer and hands out a short-lived link. A catalog lists a paid item as usual, with two differences:

- **The item** has `"pricing": {"model": "paid", "amount": 499, "currency": "USD", "licence": "per-seat"}`.
- **Its versions** keep their `archive` (url, SHA-256 and size: the pin) and add `"access": "entitled"` and `"download": {"broker": "https://…"}`.

Until the broker exists, the store shows such items but won't install them.

---

## Names baked into the code

| Name | Where |
|---|---|
| The official catalog `https://store.justunknown.com/index.json`, which calls itself `just` | `lib/src/sources/store_source.dart`: `SourceConfig.official`, `SourceConfig.officialId` |
| The store tool's version the workflows install | `STORE_VERSION` in the three workflows in `templates/` |
| A catalog's homepage, maintainers and publishers | `templates/catalog/catalog.json`, `templates/catalog/publishers/` |

---

## When something goes wrong

| What you see | What it means |
|---|---|
| Release workflow: "Tag v1.2.0 but pubspec says 1.1.0" | The tag must equal `v` plus the pubspec's version. |
| Release workflow: "CHANGELOG.md has no '## 1.2.0' section" | Add the version's section to `CHANGELOG.md`, then tag again. |
| Validate: "does not match its catalog fingerprint (SHA-256)" | The Release asset changed after its version file was written. Release a new version instead. |
| Validate: "No version of X fits" or "is not in any of your sources" | A dependency isn't in the catalog yet, or no listed version fits. Release and list it first. |
| Validate: "… is not directly in an asset folder, so it would not ship" | Move the file up into a listed folder, or list its folder in both the pubspec and the manifest. |
| Validate: "Its manifest and the catalog disagree on the store items it needs" | Make the version file's `dependencies` the manifest's. |
| Validate: "CODEOWNERS" diff | Run `just store index codeowners . --file .github/CODEOWNERS` and commit it. |
| The store says "Offline: using the cached … catalog" | The catalog couldn't be reached. The store keeps working from its cached copy. |
| Install: "pub get failed … version solving failed" | A dependency isn't on pub.dev yet. Nothing was changed in the project. |

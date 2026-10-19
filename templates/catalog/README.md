# Just Asset Store catalog

This repository is the store's catalog. Every merge to `main` builds `index.json` and publishes it on GitHub Pages, and the editor's Asset Store reads it from there. The items' archives aren't stored here. Each one lives on a GitHub Release in its own repository, and the catalog pins it by SHA-256.

## Layout

```text
catalog.json                     the source's name, the categories, the maintainers
publishers/<publisher>.json      a publisher: name, GitHub handles, trust
items/<id>/item.json             an item, without its versions
items/<id>/versions/<v>.json     one per version (written by `just store pack`)
items/<id>/thumbnail.png         its card picture, at most 512 KB (optional)
items/<id>/previews/*.png        pictures for its details pane (optional)
```

- **Trust** comes from the publisher's file: `official`, `verified` or `community`. An item can't set its own.
- **`CODEOWNERS`** gives each publisher their own `items/<id>/` folders. Regenerate it with `just store index codeowners . > .github/CODEOWNERS` after adding a publisher or an item.

## Adding a version

1. In the item's repository, push a tag `v<version>`. Its release workflow attaches the archive and its version file to a Release.
2. Here, add `items/<id>/versions/<version>.json` from that release (and `items/<id>/item.json` for a new item), and open a pull request.
3. The validate workflow checks three things:
   - the catalog builds
   - each changed item's archive downloads, matches its pinned SHA-256 and passes the installer's checks
   - CODEOWNERS is current
4. A maintainer merges it, and the publish workflow updates the store.

## Opening to community publishers (later)

Add `publishers/<their-id>.json` with their GitHub handles and `"trust": "community"`, then regenerate CODEOWNERS. Turn on branch protection with "Require review from Code Owners". From then on:
- **Content items** are reviewed lightly. The automatic checks do most of the work.
- **Code items** from non-official publishers need a public `sourceRepo`, and a maintainer reviews every version. They may not have build hooks or native plugins.
- **Taking an item down:** set `"blocked": true` on its versions (for a licence problem or a DMCA notice). Every project that has it installed then gets a warning in the editor.

## Paid items (later)

A paid item is still listed here, because its details are public. Its versions set `"access": "entitled"` and a `download.broker` URL instead of an archive URL. The broker is a small download service that checks the buyer and hands out a short-lived link. The catalog format already has these fields. The editor will turn them on once the service exists.

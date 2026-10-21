# A Just Asset Store catalog

This repository is a store catalog of your own, served from GitHub Pages: every merge to `main` builds `index.json` and publishes it at `https://<owner>.github.io/<repo>/index.json`. Projects read it once it is added as a source: `just store sources add https://<owner>.github.io/<repo>/index.json` (or the editor's Asset Store → Sources). The items' archives aren't stored here: each lives on a GitHub Release in its own repository, and the catalog pins it by SHA-256.

The store vouches only for what its official catalog lists: the items of every other catalog, this one included, are shown to users as community items, whatever `trust` says here.

## Setting it up

1. Put your name and GitHub handle in `catalog.json` (`source`, `maintainers`) and in `publishers/` (rename `your_name.json`; its `id` is the file's name).
2. Settings → Pages → Source: **GitHub Actions**. Run the **Publish** workflow once.
3. Protect `main`: require the **validate** check, and a review from Code Owners.

## Layout

```text
catalog.json                     the source's id and name, the categories, the maintainers
publishers/<publisher>.json      a publisher: name, GitHub handles, trust
items/<id>/item.json             an item, without its versions; "publisher" names its publisher
items/<id>/versions/<v>.json     one per version (written by `just store pack`)
items/<id>/thumbnail.png         its card picture, at most 512 KB (optional)
items/<id>/previews/*.png        pictures for its details pane (optional)
```

- **Trust** comes from the publisher's file: `official`, `verified` or `community`. An item can't set its own, and only the maintainers approve changes to `publishers/`.
- **`CODEOWNERS`** gives each publisher their own `items/<id>/` folders. Regenerate it after adding a publisher or an item: `just store index codeowners . --file .github/CODEOWNERS`.

## Adding a version

1. In the item's repository, push a tag `v<version>`. Its release workflow attaches the archive and its version file to a Release.
2. Here, add `items/<id>/versions/<version>.json` from that release (and `items/<id>/item.json` for a new item), and open a pull request.
3. The validate workflow checks three things:
   - the catalog builds
   - each changed item's archive downloads, matches its pinned SHA-256 and passes the installer's checks
   - CODEOWNERS is current
4. A maintainer merges it, and the publish workflow updates the catalog.

## Opening to other publishers

Add `publishers/<their-id>.json` with their GitHub handles and `"trust": "community"`, then regenerate CODEOWNERS. From then on:
- **Content items** are reviewed lightly. The automatic checks do most of the work.
- **Code items** need a public `sourceRepo`, and a maintainer reviews every version. The store itself refuses build hooks and platform folders; whether to accept native plugins is this catalog's policy.
- **Taking an item down:** set `"blocked": true` on its versions (for a licence problem or a DMCA notice). Every project that has one installed is then warned by the store.

## Paid items (later)

A paid item is still listed here, because its details are public. Its versions keep their `archive` (url, SHA-256 and size: the pin), and add `"access": "entitled"` and a `download.broker` URL: a small download service that checks the buyer and hands out a short-lived link. The catalog format already has these fields; the store turns them on once the service exists.

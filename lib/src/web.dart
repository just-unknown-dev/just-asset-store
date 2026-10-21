/// What `package:just_asset_store/just_asset_store.dart` adds on the web:
/// nothing.
///
/// The store itself (`native.dart`) reads and writes a project's files,
/// downloads and runs pub, so on the web — JavaScript or WebAssembly — the
/// library holds only what works in memory: catalogs, item manifests, the
/// package checks, the lockfile, the generated registries' text, the
/// store's pubspec block, versions, SHA-256 and ZIP archives.
library;

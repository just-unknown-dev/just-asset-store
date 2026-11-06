/// What `package:just_asset_store/just_asset_store.dart` exports on the web
/// in place of each folder that needs `dart:io`: nothing.
///
/// The store itself (`project/`, `sources/`, `publishing/`, `install/`,
/// `store/` and `commands/`) reads and writes a project's files, downloads
/// and runs pub, so on the web — JavaScript or WebAssembly — the library
/// holds only what works in memory: catalogs, item manifests, the package
/// checks, the lockfile and its file hashes, the generated registries'
/// text, the store's pubspec block, versions, SHA-256 and ZIP archives.
library;

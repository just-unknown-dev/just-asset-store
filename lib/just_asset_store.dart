/// The core of the Just Asset Store: catalogs, downloads, verification, and
/// installing items into a project as packages.
///
/// Every store item is a Dart package. Content (art, sound, tilesets) is an
/// asset-only package; editor extensions and kits are code. Installed items
/// live in `packages/{category}/{name}/`, so their assets load as
/// `packages/<name>/...` — the same key in the editor and in the game.
///
/// **On every platform, the web included (JavaScript and WebAssembly):**
/// - [StoreIndex], a catalog's `index.json`, with its [StoreItem]s and
///   their [StoreItemVersion]s; [ItemManifest], a package's
///   `just_store.json`.
/// - [PackageCheck]: the rules a downloaded package must pass, run on its
///   archive in memory.
/// - [StoreLock], a project's `just_store.lock.json`; [StoreCodegen], the
///   text of the registries the store generates; [storeBlock], the store's
///   block in a pubspec, edited with [PubspecEditor].
/// - From just_core_cli: [Version] and [VersionConstraint], [JsonFields],
///   [PackageNames], [Sha256], and [ZipArchive] and [ZipWriter] with
///   [SafePaths].
///
/// **Where `dart:io` is (Windows, macOS, Linux, Android, iOS)**, the library
/// also exports what works on a project on disk: [AssetStore], with its
/// [StoreSource]s, [Downloader], [Planner] and [StoreInstaller];
/// [StoreProject], [StoreRestore] and [StoreLinker]; the creator tools
/// [Packer] and [CatalogBuilder]; and [StoreCommand], the `just store`
/// commands.
library;

export 'src/archive/safe_paths.dart';
export 'src/archive/zip_reader.dart';
export 'src/archive/zip_writer.dart';
export 'src/catalog/item_manifest.dart';
export 'src/catalog/json.dart';
export 'src/catalog/names.dart';
export 'src/catalog/semver.dart';
export 'src/catalog/store_index.dart';
export 'src/crypto/sha256.dart';
export 'src/install/package_check.dart';
export 'src/project/codegen.dart';
export 'src/project/lockfile.dart';
export 'src/project/pubspec_editor.dart';
export 'src/version.dart';
// The store on disk where there is a machine; nothing more on the web. The
// native barrel is the default, so the analyzer and dartdoc see it.
export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';

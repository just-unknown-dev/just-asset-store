/// The core of the Just Asset Store: catalogs, downloads, verification, and
/// installing items into a project as packages.
///
/// Every store item is a Dart package. Content (art, sound, tilesets) is an
/// asset-only package installed in `packages/{category}/{name}/`; its
/// assets load as `packages/<name>/...` — the same key in the editor and in
/// the game. Editor extensions and kits are code, plugins that come only
/// through the store, installed in `plugins/{category}/{name}/`.
///
/// **On every platform, the web included (JavaScript and WebAssembly):**
/// - [StoreIndex], a catalog's `index.json`, with its [StoreItem]s and
///   their [StoreItemVersion]s; [ItemManifest], a package's
///   `just_store.json`; [JustRelease], a release's `just_release.json`.
/// - [PackageCheck]: the rules a downloaded package must pass, run on its
///   archive in memory.
/// - [StoreLock], a project's `just_store.lock.json`, with the
///   [FileHashes] it records; [StoreCodegen], the text of the registries
///   the store generates; [storeBlock], the store's block in a pubspec,
///   edited with [PubspecEditor].
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
///
/// Each part is one folder of `lib/src`, exported whole by its barrel; the
/// folders that need `dart:io` are exported only where there is one
/// (`dart.library.js_interop` picks the empty `src/web.dart` instead).
library;

export 'src/catalog/catalog.dart';
export 'src/checks/checks.dart';
export 'src/lockfile/lockfile.dart';
export 'src/version.dart';
// The store on disk where there is a machine; nothing more on the web. The
// native barrels are the default, so the analyzer and dartdoc see them.
export 'src/project/project.dart' if (dart.library.js_interop) 'src/web.dart';
export 'src/sources/sources.dart' if (dart.library.js_interop) 'src/web.dart';
export 'src/publishing/publishing.dart'
    if (dart.library.js_interop) 'src/web.dart';
export 'src/install/install.dart' if (dart.library.js_interop) 'src/web.dart';
export 'src/store/store.dart' if (dart.library.js_interop) 'src/web.dart';
export 'src/commands/commands.dart' if (dart.library.js_interop) 'src/web.dart';

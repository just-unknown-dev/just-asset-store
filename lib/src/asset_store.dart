/// One project's store: its sources, cache, catalog, plans and installs —
/// what the editor's store window and `just store` both drive.
library;

import 'dart:async';
import 'dart:io';

import 'catalog/item_manifest.dart';
import 'catalog/store_index.dart';
import 'install/installer.dart';
import 'install/planner.dart';
import 'install/restore.dart';
import 'project/lockfile.dart';
import 'project/overrides_target.dart';
import 'project/pub_runner.dart';
import 'project/reference_scan.dart';
import 'project/store_project.dart';
import 'sources/downloader.dart';
import 'sources/store_source.dart';

/// How fetching one source's catalog went.
final class SourceStatus {
  /// The status of [config].
  const SourceStatus(
    this.config, {
    this.info,
    this.items = 0,
    this.offline = false,
    this.error,
  });

  /// The source's settings.
  final SourceConfig config;

  /// What its catalog says about it, when it loaded.
  final StoreSourceInfo? info;

  /// How many items it lists.
  final int items;

  /// Whether the cached catalog was used because fetching failed.
  final bool offline;

  /// Why it could not be read (or why it is [offline]).
  final Object? error;

  /// Whether its catalog could be read at all.
  bool get loaded => info != null;

  /// The name to show.
  String get name => info?.name ?? config.name ?? config.url;
}

/// The merged catalog and how each source fared.
final class LoadedCatalog {
  /// [catalog] built from [sources].
  const LoadedCatalog(this.catalog, this.sources);

  /// Every enabled source's items, merged.
  final StoreCatalog catalog;

  /// Each source's status, in order.
  final List<SourceStatus> sources;
}

/// The store for one project.
final class AssetStore {
  /// The store for [project], reading [sources] (the official catalog by
  /// default), caching downloads in [cacheDir], resolving with [pub] (else
  /// the project's Flutter SDK, or [sdkPath]).
  AssetStore({
    required this.project,
    List<SourceConfig>? sources,
    String? cacheDir,
    PubRunner? pub,
    String? sdkPath,
    HttpClient Function()? client,
  }) : sources = sources ?? const [SourceConfig.official],
       cacheDir = cacheDir,
       _client = client,
       downloader = Downloader(
         cache: cacheDir == null ? null : DownloadCache(cacheDir),
       ),
       pub = pub ?? _pubFor(project, sdkPath);

  /// The project.
  final StoreProject project;

  /// The sources, in priority order.
  final List<SourceConfig> sources;

  /// Where downloads and catalogs are cached.
  final String? cacheDir;

  /// Fetches archives (through the cache).
  final Downloader downloader;

  /// Runs `pub get`.
  final PubRunner pub;

  final HttpClient Function()? _client;

  final Map<String, StoreSource> _sources = {};

  /// The source for [config].
  StoreSource sourceFor(SourceConfig config) => _sources.putIfAbsent(
    config.url,
    () => StoreSource.from(config, cacheDir: cacheDir, client: _client),
  );

  /// Reads every enabled source's catalog. A source that fails is reported
  /// in [LoadedCatalog.sources], not thrown.
  Future<LoadedCatalog> loadCatalog({bool refresh = false}) async {
    final statuses = <SourceStatus>[];
    final catalogs = <(String, StoreSource?, StoreIndex)>[];
    for (final config in sources.where((s) => s.enabled)) {
      try {
        final source = sourceFor(config);
        final fetched = await source.fetchIndex(refresh: refresh);
        final index = await source.withPages(fetched.index);
        catalogs.add((index.source.id, source, index));
        statuses.add(
          SourceStatus(
            config,
            info: index.source,
            items: index.items.length,
            offline: fetched.offline,
            error: fetched.error,
          ),
        );
      } on Object catch (e) {
        statuses.add(SourceStatus(config, error: e));
      }
    }
    return LoadedCatalog(StoreCatalog(catalogs), statuses);
  }

  /// Which overrides file pub reads.
  Future<OverridesTarget> target() => OverridesTarget.detect(project);

  /// What the project has now.
  Future<ProjectState> state() async =>
      ProjectState.read(project, await target());

  /// A planner over [catalog] (or a freshly loaded one) and the project.
  Future<Planner> planner({StoreCatalog? catalog}) async =>
      Planner(catalog ?? (await loadCatalog()).catalog, await state());

  /// An installer for the project.
  StoreInstaller installer() =>
      StoreInstaller(project: project, pub: pub, downloader: downloader);

  /// What in the project still uses the installed item [id]. The folders of
  /// the items in [ignoring] (going too) are not searched.
  List<PackageReference> referencesTo(
    String id, {
    Set<String> ignoring = const {},
  }) {
    final lock = project.readLock();
    final item = lock.items[id];
    ItemManifest? manifest;
    final path = item?.path;
    if (path != null) {
      final f = project.file('$path/${ItemManifest.fileName}');
      if (f.existsSync()) {
        try {
          manifest = ItemManifest.parse(f.readAsStringSync());
        } on Object {
          // No component list to search for.
        }
      }
    }
    return ReferenceScan.find(
      project,
      id,
      componentTypes: manifest?.componentTypes ?? const [],
      alsoSearch: [
        for (final e in lock.items.entries)
          if (e.key != id && !ignoring.contains(e.key) && e.value.path != null)
            e.value.path!,
      ],
      excluding: path,
    );
  }

  /// Plans removing [id], with what still uses it and the dependencies that
  /// would go with it.
  Future<InstallPlan> planUninstall(String id, {StoreCatalog? catalog}) async =>
      (await planner(catalog: catalog)).uninstall(
        id,
        references: referencesTo(id),
        referencesOf: (dep, going) => referencesTo(dep, ignoring: going),
      );

  /// Downloads the locked items whose folders are missing.
  Future<RestoreResult> restore({
    void Function(InstallProgress)? onProgress,
    CancelToken? cancel,
  }) => StoreRestore.run(
    project,
    pub: pub,
    downloader: downloader,
    client: _client,
    onProgress: onProgress,
    cancel: cancel,
  );

  /// The installed items, by id.
  Map<String, LockedItem> get installed => project.readLock().items;

  static PubRunner _pubFor(StoreProject project, String? sdkPath) {
    final sdk = SdkLocator.locate(project.root, configured: sdkPath);
    return sdk == null ? const _NoSdk() : ProcessPubRunner(sdk);
  }
}

final class _NoSdk implements PubRunner {
  const _NoSdk();

  @override
  Future<PubResult> get(String projectRoot, {bool offline = false}) async =>
      const PubResult(
        1,
        '',
        'The Flutter SDK was not found. Set its folder in the Asset Store '
            'settings, or run `flutter pub get` once in this project.',
      );
}

/// One project's store: its sources, cache, catalog, plans and installs —
/// what the editor's store window and `just store` both drive.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/project.dart';

import '../catalog/item_manifest.dart';
import '../catalog/store_index.dart';
import '../install/install_plan.dart';
import '../install/planner.dart';
import '../install/project_state.dart';
import '../install/store_catalog.dart';
import '../install/store_installer.dart';
import '../install/store_restore.dart';
import '../lockfile/store_lock.dart';
import '../project/local_edits.dart';
import '../project/reference_scan.dart';
import '../project/store_project.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';

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

  /// What went wrong, as a sentence for a person; null when nothing did.
  String? get problem => switch (error) {
    null => null,
    FetchException(:final message) => message,
    DownloadException(:final message) => message,
    JsonFormatException() => 'Its catalog could not be read ($error).',
    final e => '$e',
  };
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
        final index = fetched.index;
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

  /// What in the project still uses each of the installed items [ids], by
  /// id ([ReferenceScan.find]), in one pass over the project's files on
  /// another isolate. The folders of the items in [ids] are not searched:
  /// they go too.
  Future<Map<String, List<PackageReference>>> referencesTo(
    Set<String> ids,
  ) async {
    final lock = project.readLock();
    final targets = <ReferenceTarget>[];
    for (final id in ids) {
      final path = lock.items[id]?.path;
      ItemManifest? manifest;
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
      targets.add(
        ReferenceTarget(
          id,
          componentTypes: manifest?.componentTypes ?? const [],
        ),
      );
    }
    final alsoSearch = [
      for (final e in lock.items.entries)
        if (!ids.contains(e.key) && e.value.path != null) e.value.path!,
    ];
    final excluding = [for (final id in ids) ?lock.items[id]?.path];
    final root = project.root;
    return Isolate.run(
      () => ReferenceScan.find(
        StoreProject(root),
        targets,
        alsoSearch: alsoSearch,
        excluding: excluding,
      ),
    );
  }

  /// Plans removing [id], with what still uses it and the dependencies that
  /// would go with it: planned once to learn what goes, then the project is
  /// scanned once for all of them ([referencesTo]), off the caller's
  /// isolate. [planner] (else one over [catalog], or a freshly loaded one)
  /// plans it.
  Future<InstallPlan> planUninstall(
    String id, {
    StoreCatalog? catalog,
    Planner? planner,
  }) async {
    final p = planner ?? await this.planner(catalog: catalog);
    final going = {id, for (final c in p.uninstall(id).changes) c.id};
    return p.uninstall(id, references: await referencesTo(going));
  }

  /// [plan] with a warning for each installed item it replaces or removes
  /// whose folder holds files changed — or added — since the store put it
  /// there ([LocalEdits], from the hashes the lockfile records): they go to
  /// the editor's trash with the folder ([InstallResult.trashFolder]), and
  /// the user should know before saying yes. Hashing runs on another
  /// isolate. A plan with nothing to replace or remove comes back as it is.
  Future<InstallPlan> withLocalEdits(InstallPlan plan) async {
    final items = <String, LockedItem>{
      for (final c in plan.changes)
        if ((c.kind == ChangeKind.update || c.kind == ChangeKind.remove) &&
            c.current != null)
          c.id: c.current!,
    };
    if (items.isEmpty) return plan;
    final root = project.root;
    final edited = await Isolate.run(
      () => LocalEdits.find(StoreProject(root), items),
    );
    if (edited.isEmpty) return plan;
    return plan.withIssues([
      for (final c in plan.changes)
        if (edited[c.id] case final files?)
          PlanIssue(
            IssueLevel.warning,
            '${files.length == 1 ? 'A file' : '${files.length} files'} of '
            '${c.name} changed since it was installed: '
            '${files.take(5).join(', ')}${files.length > 5 ? '…' : ''}. '
            '${c.kind == ChangeKind.update ? 'The update replaces' : 'Uninstalling removes'} '
            'the folder; the old one goes to the trash '
            '(${StoreProject.trashRoot}/${StoreProject.trash}/), where '
            '${files.length == 1 ? 'it is' : 'they are'} kept.',
            id: c.id,
          ),
    ]);
  }

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

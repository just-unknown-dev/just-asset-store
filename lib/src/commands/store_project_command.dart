/// What every `just store` command that works on a project shares.
library;

import 'dart:io';

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/just_core_cli.dart';
import 'package:meta/meta.dart';

import '../catalog/item_traits.dart';
import '../checks/package_check.dart';
import '../install/install_plan.dart';
import '../install/item_source.dart';
import '../install/store_catalog.dart';
import '../install/store_installer.dart';
import '../lockfile/store_lock.dart';
import '../project/store_paths.dart';
import '../project/store_project.dart';
import '../sources/store_source.dart';
import '../store/asset_store.dart';

/// What every store command in a project shares: the project, its sources,
/// the cache and the SDK.
@internal
abstract class StoreProjectCommand extends JustCommand {
  /// Adds the options for reading catalogs and running pub. Every store
  /// command in a project accepts them, so a script can pass the same
  /// options to each; [catalogs] is false for those that don't read
  /// catalogs or run pub, which hides them from its help (but for
  /// `--cache` when [cache] says it is used).
  StoreProjectCommand({bool catalogs = true, bool? cache}) {
    {
      argParser
        ..addMultiOption(
          'source',
          valueHelp: 'url',
          help:
              "A catalog to read; repeat for several. Default: the project's "
              'sources, else the official catalog.',
          hide: !catalogs,
        )
        ..addOption(
          'cache',
          valueHelp: 'folder',
          help: 'Where downloads are kept (default: per user).',
          hide: !(cache ?? catalogs),
        )
        ..addOption(
          'sdk',
          valueHelp: 'folder',
          help: "The Flutter SDK (default: the project's).",
          hide: !catalogs,
        );
    }
  }

  /// The project, as the store sees it.
  StoreProject get storeProject => StoreProject(requireProject().root);

  /// The catalogs to read: `--source`, else the lockfile's (a folder by its
  /// path from the project), else the official one.
  List<SourceConfig> sourcesFor(StoreProject project) {
    final given = argResults!.multiOption('source');
    if (given.isNotEmpty) {
      return [for (final s in given) SourceConfig(here(s, url: true))];
    }
    final locked = project.readLock().sources;
    if (locked.isNotEmpty) {
      // The lockfile is shared with the project: a folder it names is read,
      // but doesn't vouch for its items as one the user names would.
      return [
        for (final s in locked)
          SourceConfig(project.sourceLocation(s.url), fromLockfile: true),
      ];
    }
    return const [SourceConfig.official];
  }

  /// The store for [project], with this run's sources, cache and SDK.
  AssetStore storeFor(StoreProject project) => AssetStore(
    project: project,
    sources: sourcesFor(project),
    cacheDir: cacheDir,
    sdkPath: switch (argResults!.option('sdk')) {
      final sdk? => here(sdk),
      null => null,
    },
  );

  /// The download cache: `--cache`, else the per-user one.
  String? get cacheDir => switch (argResults!.option('cache')) {
    final dir? => here(dir),
    null => StorePaths.defaultCacheDir(),
  };

  /// [path] as the user typed it, from the folder they were in (`just`
  /// runs the plugin in the project's folder). With [url], an address (a
  /// web or `file:` URL, a GitHub repository) is left as it is.
  String here(String path, {bool url = false}) =>
      url &&
          (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:').hasMatch(path) ||
              GitHubSource.tryFrom(path) != null)
      ? path
      : absoluteIn(path, context.workingDirectory);

  /// The catalog, saying which sources could not be read or are offline.
  Future<LoadedCatalog> loadCatalog(AssetStore store) async {
    final loaded = await store.loadCatalog();
    for (final s in loaded.sources) {
      if (s.error != null && s.items == 0 && !s.offline) {
        output.warn('Could not read ${s.name}: ${s.error}');
      }
      if (s.offline) {
        output.info('Offline: using the cached ${s.name} catalog.');
      }
    }
    return loaded;
  }

  /// [body], with the store's own failures — an install that failed and
  /// was undone, a package refused, a download or a catalog that could not
  /// be read — as this command's: their message and exit code 1, never an
  /// unexpected error.
  Future<T> storeFailures<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on InstallFailure catch (e) {
      throw CommandFailure(e.message);
    } on PackageCheckException catch (e) {
      throw CommandFailure('$e');
    } on FetchException catch (e) {
      throw CommandFailure('$e');
    } on DownloadException catch (e) {
      throw CommandFailure(e.message);
    }
  }

  /// Where [entry] comes from and how finished it is: `Official · Beta`.
  /// A stable item shows no stage.
  String tags(CatalogEntry entry, LockedItem? installed) => [
    ItemSource.of(entry: entry, installed: installed).label,
    if (entry.item.stage case final stage? when stage != ItemStage.stable)
      stage.label,
  ].join(' · ');

  /// Prints [planned] — with a warning for each item whose folder was
  /// changed by hand ([AssetStore.withLocalEdits]) — asks, and applies it.
  /// Exit code 0 when applied or nothing to do, 1 when blocked or declined.
  Future<int> applyPlan(AssetStore store, InstallPlan planned) async {
    final plan = await store.withLocalEdits(planned);
    printPlan(plan);
    output.result = planJson(plan);
    if (!plan.canApply) return plan.blockers.isEmpty ? 0 : 1;
    if (!confirm('Apply?')) {
      output.info('Nothing was changed.');
      return 1;
    }
    final result = await storeFailures(
      () =>
          store.installer().apply(plan, onProgress: (p) => output.info('  $p')),
    );
    output.line('Done.');
    if (result.trashFolder case final trash?
        when plan.issues.length != planned.issues.length) {
      output.line('The folders it replaced or removed are in $trash.');
    }
    for (final e in result.setupSnippets.entries) {
      output.line('\n${e.key} needs this in your game code:\n${e.value}');
    }
    if (result.needsRestart) {
      output.line(
        '\nRestart the editor (or hot restart) to load the new code.',
      );
    }
    output.result = {
      ...planJson(plan),
      'applied': true,
      'needsRestart': result.needsRestart,
      'setup': result.setupSnippets,
      'notes': result.notes,
    };
    return 0;
  }

  /// Prints [plan]: each change with its reason, then each issue, or
  /// "Nothing to do." when there is neither.
  void printPlan(InstallPlan plan) {
    if (plan.changes.isNotEmpty) output.line('Plan:');
    for (final c in plan.changes) {
      final what = switch (c.kind) {
        ChangeKind.install => '+ install   ${c.id} ${c.version!.version}',
        ChangeKind.update =>
          '~ update    ${c.id} ${c.current?.version} -> ${c.version!.version}',
        ChangeKind.remove => '- uninstall ${c.id}',
        ChangeKind.adopt =>
          '= keep      ${c.id} ${c.current?.version}, as one of yours',
      };
      output.line('  $what  (${c.reason})');
    }
    for (final i in plan.issues) {
      final mark = switch (i.level) {
        IssueLevel.blocker => 'x',
        IssueLevel.warning => '!',
        IssueLevel.info => 'i',
      };
      output.line('  $mark ${i.message}');
    }
    if (plan.changes.isEmpty && plan.issues.isEmpty) {
      output.line('Nothing to do.');
    }
  }

  /// [plan] for `--json`.
  Map<String, Object?> planJson(InstallPlan plan) => {
    'changes': [
      for (final c in plan.changes)
        {
          'kind': c.kind.name,
          'id': c.id,
          'from': c.current?.version,
          'to': c.version == null ? null : '${c.version!.version}',
          'reason': c.reason,
        },
    ],
    'issues': [
      for (final i in plan.issues)
        {'level': i.level.name, 'message': i.message},
    ],
    'canApply': plan.canApply,
  };
}

/// [path] made absolute against [cwd].
@internal
String absoluteIn(String path, String cwd) =>
    File(path).isAbsolute ? path : '$cwd/$path';

/// `just store …`: the Asset Store's commands, as a just_core_cli plugin.
library;

import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';

import '../asset_store.dart';
import '../catalog/store_index.dart';
import '../install/installer.dart';
import '../install/item_source.dart';
import '../install/linker.dart';
import '../install/package_check.dart';
import '../install/planner.dart';
import '../project/lockfile.dart';
import '../project/registry.dart';
import '../project/store_paths.dart';
import '../project/store_project.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';
import 'creator_commands.dart';
import 'template_command.dart';

/// `just store`: install, update and remove Asset Store items, and the
/// creators' tools.
final class StoreCommand extends JustCommand {
  /// The command and all its subcommands.
  StoreCommand() {
    for (final c in <JustCommand>[
      InstallCommand(),
      UpdateCommand(),
      UninstallCommand(),
      ListCommand(),
      SearchCommand(),
      InfoCommand(),
      RestoreCommand(),
      GenerateCommand(),
      LinkCommand(),
      UnlinkCommand(),
      VendorCommand(),
      SourcesCommand(),
      CacheCommand(),
      PackCommand(),
      ValidateCommand(),
      IndexCommand(),
      TemplateCommand(),
    ]) {
      addSubcommand(c);
    }
  }

  @override
  String get name => 'store';

  @override
  String get description =>
      'Install, update and remove Asset Store items, and pack your own.';
}

/// What every store command in a project shares: the project, its sources,
/// the cache and the SDK.
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

  /// The catalogs to read: `--source`, else the lockfile's, else the
  /// official one.
  List<SourceConfig> sourcesFor(StoreProject project) {
    final given = argResults!.multiOption('source');
    if (given.isNotEmpty) {
      return [for (final s in given) SourceConfig(here(s, url: true))];
    }
    final locked = project.readLock().sources;
    if (locked.isNotEmpty) return [for (final s in locked) SourceConfig(s.url)];
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

  /// Prints [plan], asks, and applies it. Exit code 0 when applied or
  /// nothing to do, 1 when blocked or declined.
  /// Where [entry] comes from and how finished it is: `Official · Beta`.
  /// A stable item shows no stage.
  String tags(CatalogEntry entry, LockedItem? installed) => [
    ItemSource.of(entry: entry, installed: installed).label,
    if (entry.item.stage case final stage? when stage != ItemStage.stable)
      stage.label,
  ].join(' · ');

  Future<int> applyPlan(AssetStore store, InstallPlan plan) async {
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

/// `just store install <id>[@<version>]` (and `just add`).
final class InstallCommand extends StoreProjectCommand {
  /// The command and its options.
  InstallCommand() {
    argParser.addFlag(
      'unlisted',
      negatable: false,
      help:
          'With --yes: install code from a GitHub repository that no catalog '
          'lists, which nobody reviewed. Without it, --yes is not enough.',
    );
  }

  @override
  String get name => 'install';

  @override
  String get description => 'Install an item, and what it needs.';

  @override
  String get invocation =>
      '${context.invokedAs} store install <id>[@<version>] | <github url>[@<tag>]';

  @override
  Future<int> run() async {
    final arg = singleArgument('an item id');
    if (arg.contains('/')) return _fromGitHub(arg);
    final parts = arg.split('@');
    final version = parts.length > 1 ? Version.tryParse(parts[1]) : null;
    if (parts.length > 2 || (parts.length > 1 && version == null)) {
      throw UsageFailure('"${parts.skip(1).join('@')}" is not a version.');
    }
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    final planner = await store.planner(catalog: loaded.catalog);
    return applyPlan(store, planner.install(parts.first, version: version));
  }

  /// An item that is in no catalog, straight from its GitHub releases:
  /// installed like any other once the user has been told nobody reviewed
  /// it. The lockfile records the release it came from and its SHA-256, so
  /// a teammate's `restore` gets the same bytes.
  Future<int> _fromGitHub(String url) async {
    final github = GitHubSource.tryFrom(url);
    if (github == null) {
      throw UsageFailure(
        '"$url" is neither an item id nor a GitHub repository '
        '(https://github.com/<owner>/<repo>[@<tag>]).',
      );
    }
    final project = storeProject;
    final release = (await storeFailures(
      () => github.fetchIndex(refresh: true),
    )).index;
    final item = release.items.single;
    output.warn(
      '${item.name} (${item.id}) is unlisted: it comes straight from '
      '${github.repo.url}, and the Asset Store has not reviewed it. '
      '${item.kind.isCode ? 'It holds code that runs on your machine. ' : ''}'
      'Install it only if you trust ${github.repo.owner}.',
    );
    // Code nobody reviewed is never installed by --yes alone: a script must
    // say it means to.
    if (item.kind.isCode && yes && !argResults!.flag('unlisted')) {
      throw CommandFailure(
        '${item.name} is unlisted code: add --unlisted to install it with '
        '--yes.',
      );
    }
    final config = SourceConfig('${github.indexUri}', name: '${github.repo}');
    final store = AssetStore(
      project: project,
      // First, so the item installed is the one just warned about, even
      // when a catalog lists another under the same id; what it needs
      // comes from the project's sources.
      sources: [config, ...sourcesFor(project)],
      cacheDir: cacheDir,
      sdkPath: switch (argResults!.option('sdk')) {
        final sdk? => here(sdk),
        null => null,
      },
    );
    final loaded = await loadCatalog(store);
    final planner = await store.planner(catalog: loaded.catalog);
    return applyPlan(store, planner.install(item.id));
  }
}

/// `just store update [<id>]`.
final class UpdateCommand extends StoreProjectCommand {
  @override
  String get name => 'update';

  @override
  String get description =>
      'Update an item, or every item installed on purpose.';

  @override
  String get invocation => '${context.invokedAs} store update [<id>]';

  @override
  Future<int> run() async {
    if (rest.length > 1) throw const UsageFailure('update takes one item id.');
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    final planner = await store.planner(catalog: loaded.catalog);
    return applyPlan(
      store,
      rest.isEmpty ? planner.updateAll() : planner.update(rest.single),
    );
  }
}

/// `just store uninstall <id>` (and `just remove`).
final class UninstallCommand extends StoreProjectCommand {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Remove an item, and what only it needed.';

  @override
  String get invocation => '${context.invokedAs} store uninstall <id>';

  @override
  Future<int> run() async {
    final id = singleArgument('an item id');
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    return applyPlan(
      store,
      await store.planUninstall(id, catalog: loaded.catalog),
    );
  }
}

/// `just store list`.
final class ListCommand extends StoreProjectCommand {
  /// Lists what the lockfile says is installed.
  ListCommand() : super(catalogs: false);

  @override
  String get name => 'list';

  @override
  String get description => 'List the installed items.';

  @override
  Future<int> run() async {
    final items = storeProject.readLock().items;
    output.result = {for (final e in items.entries) e.key: e.value.toJson()};
    if (items.isEmpty) {
      output.line('No items installed.');
      return 0;
    }
    for (final e in items.entries) {
      final i = e.value;
      final flags = [
        i.kind.id,
        ItemSource.ofInstalled(i).label,
        if (!i.direct) 'dependency',
        if (i.system) 'system',
      ].join(', ');
      output.line(
        '${e.key} ${i.version}  ($flags)${i.path == null ? '' : '  ${i.path}'}',
      );
    }
    return 0;
  }
}

/// `just store search [<words>]`.
final class SearchCommand extends StoreProjectCommand {
  /// Searches the catalogs, optionally in one category.
  SearchCommand() {
    argParser.addOption(
      'category',
      valueHelp: 'id',
      help: 'Only items in this category.',
    );
  }

  @override
  String get name => 'search';

  @override
  String get description => 'Find items in the catalogs.';

  @override
  String get invocation => '${context.invokedAs} store search [<words>]';

  @override
  Future<int> run() async {
    final query = rest.join(' ');
    final category = argResults!.option('category');
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    final installed = project.readLock().items;
    final found = [
      for (final e in loaded.catalog.entries)
        if ((query.isEmpty || e.item.matches(query)) &&
            (category == null || e.item.category == category))
          e,
    ]..sort((a, b) => a.item.id.compareTo(b.item.id));
    output.result = [
      for (final e in found)
        {
          'id': e.item.id,
          'name': e.item.name,
          'kind': e.item.kind.id,
          'category': e.item.category,
          'latest': e.item.latest == null ? null : '${e.item.latest!.version}',
          'summary': e.item.summary,
          'trust': e.item.trust.name,
          'source': e.sourceId,
          'from': ItemSource.of(entry: e, installed: installed[e.item.id]).id,
          'stage': e.item.stage?.id,
          'replacedBy': e.item.replacedBy,
          'installed': installed[e.item.id]?.version,
        },
    ];
    if (found.isEmpty) {
      output.line(query.isEmpty ? 'The catalogs are empty.' : 'Nothing found.');
      return 0;
    }
    for (final e in found) {
      final item = e.item;
      final mark = installed.containsKey(item.id) ? '*' : ' ';
      final latest = item.latest == null ? '' : ' ${item.latest!.version}';
      output.line(
        '$mark ${item.id}$latest  ${item.name} — ${item.kind.id}, '
        '${item.category} · ${tags(e, installed[item.id])}',
      );
      if (item.summary.isNotEmpty) output.line('    ${item.summary}');
    }
    return 0;
  }
}

/// `just store info <id>`.
final class InfoCommand extends StoreProjectCommand {
  @override
  String get name => 'info';

  @override
  String get description => 'Show one item: versions, author, licence.';

  @override
  String get invocation => '${context.invokedAs} store info <id>';

  @override
  Future<int> run() async {
    final id = singleArgument('an item id');
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    final installed = project.readLock().items[id];
    final removal = loaded.catalog.removal(id, source: installed?.source);
    if (removal != null) {
      output
        ..result = {'id': id, 'removed': removal.reason}
        ..warn(
          '$id was taken down by the store: ${removal.reason}'
          '${installed == null ? '' : ' Uninstall it.'}',
        );
      return installed == null ? 1 : 0;
    }
    final entry = loaded.catalog.entry(id);
    if (entry == null) throw CommandFailure('No item "$id" in the catalogs.');
    final item = entry.item;
    output.result = {
      ...item.toJson(),
      'source': entry.sourceId,
      'from': ItemSource.of(entry: entry, installed: installed).id,
      'stage': item.stage?.id,
      'installed': installed?.toJson(),
    };
    output
      ..line('${item.name} (${item.id})')
      ..line('  ${item.kind.id}, ${item.category} · ${tags(entry, installed)}');
    switch (item.stage) {
      case ItemStage.deprecated:
        final by = item.replacedBy;
        output.warn(
          '${item.name} is deprecated: it is no longer developed.'
          '${by == null ? '' : ' Use ${loaded.catalog.entry(by)?.item.name ?? by} ($by) instead.'}',
        );
      case ItemStage.experimental:
        output.line('  Experimental: it may change or break between versions.');
      case ItemStage.stable || ItemStage.beta || null:
        break;
    }
    if (item.summary.isNotEmpty) output.line('  ${item.summary}');
    if (item.author != null) output.line('  by ${item.author!.name}');
    if (item.license != null) output.line('  licence ${item.license!.spdx}');
    if (item.sourceRepo != null) output.line('  ${item.sourceRepo}');
    final latest = item.latest;
    if (latest != null && latest.permissions.isNotEmpty) {
      output.line(
        '  ${latest.version} ${ItemPermission.describe(latest.permissions)}.',
      );
    }
    output.line('  versions:');
    for (final v in item.versions.reversed) {
      final marks = [
        if (installed?.version == '${v.version}') 'installed',
        if (v.blocked) 'taken down' else if (v.yanked) 'withdrawn',
      ];
      output.line(
        '    ${v.version}${marks.isEmpty ? '' : '  (${marks.join(', ')})'}',
      );
    }
    final running = installed == null
        ? null
        : item.versionOf(
            Version.tryParse(installed.version) ?? Version(0, 0, 0),
          );
    if (running != null && running.blocked) {
      output.warn(
        'The installed ${running.version} was taken down by its catalog: '
        'update it, or uninstall it.',
      );
    }
    return 0;
  }
}

/// `just store restore`.
final class RestoreCommand extends StoreProjectCommand {
  @override
  String get name => 'restore';

  @override
  String get description =>
      'Download installed items whose folders are missing.';

  @override
  Future<int> run() async {
    final store = storeFor(storeProject);
    final result = await store.restore(onProgress: (p) => output.info('$p'));
    for (final id in result.restored) {
      output.line('Restored $id.');
    }
    for (final p in result.problems) {
      output.warn(p);
    }
    if (result.restored.isEmpty && result.problems.isEmpty) {
      output.line('Nothing is missing.');
    }
    output.result = {'restored': result.restored, 'problems': result.problems};
    return result.problems.isEmpty ? 0 : 1;
  }
}

/// `just store generate [--check]`.
final class GenerateCommand extends StoreProjectCommand {
  /// Rewrites, or checks, the generated registry files.
  GenerateCommand() : super(catalogs: false) {
    argParser.addFlag(
      'check',
      negatable: false,
      help: 'Change nothing; fail when they are out of date.',
    );
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Rewrite the generated registry files (lib/editor/store_modules.g.dart, '
      'lib/game/store_extensions.g.dart).';

  @override
  Future<int> run() async {
    final project = storeProject;
    if (argResults!.flag('check')) {
      final stale = StoreRegistry.outdated(project);
      output.result = {'outdated': stale};
      if (stale.isEmpty) {
        output.line('The generated files are up to date.');
        return 0;
      }
      throw CommandFailure(
        'Out of date: ${stale.join(', ')}. Run `${context.invokedAs} store '
        'generate` to fix.',
      );
    }
    final problems = <String>[];
    final written = await storeFailures(
      () async => StoreInstaller.withLockSync(
        project,
        () => StoreRegistry.write(project, problems: problems),
      ),
    );
    for (final p in problems) {
      output.warn(p);
    }
    output
      ..result = {'written': written, 'problems': problems}
      ..line(
        written.isEmpty
            ? 'Already up to date.'
            : 'Wrote ${written.join(', ')}.',
      );
    return problems.isEmpty ? 0 : 1;
  }
}

/// `just store link <folder>...`.
final class LinkCommand extends StoreProjectCommand {
  /// Records checkouts without moving them.
  LinkCommand() : super(catalogs: false);

  @override
  String get name => 'link';

  @override
  String get description =>
      'Record your own checkouts of store items: listed and registered, '
      'never moved or updated.';

  @override
  String get invocation => '${context.invokedAs} store link <folder>...';

  @override
  Future<int> run() async {
    if (rest.isEmpty) throw const UsageFailure('link needs folders.');
    final project = storeProject;
    final ids = await storeFailures(
      () async => StoreLinker.link(project, [for (final f in rest) here(f)]),
    );
    output
      ..result = {'linked': ids}
      ..line('Linked ${ids.join(', ')}.');
    return 0;
  }
}

/// `just store unlink <id>`.
final class UnlinkCommand extends StoreProjectCommand {
  /// Forgets a linked item.
  UnlinkCommand() : super(catalogs: false);

  @override
  String get name => 'unlink';

  @override
  String get description => 'Forget a linked item (its checkout stays).';

  @override
  String get invocation => '${context.invokedAs} store unlink <id>';

  @override
  Future<int> run() async {
    final id = singleArgument('an item id');
    final project = storeProject;
    if (!await storeFailures(() async => StoreLinker.unlink(project, id))) {
      throw CommandFailure('$id is not a linked item.');
    }
    output
      ..result = {'unlinked': id}
      ..line('Unlinked $id.');
    return 0;
  }
}

/// `just store vendor <id>...`.
final class VendorCommand extends StoreProjectCommand {
  @override
  String get name => 'vendor';

  @override
  String get description =>
      'Copy linked items into the project as installed items: editor tools '
      'and kits into plugins/{category}/{name}/, content into '
      'packages/{category}/{name}/ (in a copy of the project without '
      'overrides pointing at the checkouts).';

  @override
  String get invocation => '${context.invokedAs} store vendor <id>...';

  @override
  Future<int> run() async {
    if (rest.isEmpty) throw const UsageFailure('vendor needs item ids.');
    final project = storeProject;
    final store = storeFor(project);
    final result = await storeFailures(
      () => StoreLinker.vendor(project, rest, pub: store.pub),
    );
    for (final c in result.changes) {
      output.line('Vendored ${c.id} into ${c.path}.');
    }
    output.result = {
      'vendored': [
        for (final c in result.changes) {'id': c.id, 'path': c.path},
      ],
    };
    return 0;
  }
}

/// `just store sources [add <url> | remove <id|url>]`.
final class SourcesCommand extends StoreProjectCommand {
  /// Lists, adds and removes the project's catalogs.
  SourcesCommand() : super(catalogs: false);

  @override
  String get name => 'sources';

  @override
  String get description =>
      'List the catalogs this project reads, or add or remove one.';

  @override
  String get invocation =>
      '${context.invokedAs} store sources [add <url> | remove <id|url>]';

  @override
  Future<int> run() async {
    final project = storeProject;
    final lock = project.readLock();
    if (rest.isEmpty) {
      final shown = lock.sources.isEmpty
          ? [LockedSource(SourceConfig.officialId, SourceConfig.official.url)]
          : lock.sources;
      output.result = [for (final s in shown) s.toJson()];
      if (lock.sources.isEmpty) {
        output.line('The official catalog (none recorded in the project):');
      }
      for (final s in shown) {
        output.line('${s.id}  ${s.url}');
      }
      return 0;
    }
    if (rest.length != 2 || (rest.first != 'add' && rest.first != 'remove')) {
      throw const UsageFailure(
        'Use: sources, sources add <url>, or '
        'sources remove <id|url>.',
      );
    }
    final target = rest[1];
    // What to add is read first (from the web, maybe); the lockfile is read
    // and written holding the project's lock, so no other change is lost.
    LockedSource? adding;
    var items = 0;
    if (rest.first == 'add') {
      final config = SourceConfig(here(target, url: true));
      final (source, fetched) = await storeFailures(() async {
        final source = storeFor(project).sourceFor(config);
        return (source, await source.fetchIndex(refresh: true));
      });
      adding = LockedSource(fetched.index.source.id, '${source.indexUri}');
      items = fetched.index.items.length;
    }
    final next = await storeFailures(
      () async => StoreInstaller.withLockSync(project, () {
        final lock = project.readLock();
        final StoreLock next;
        if (adding != null) {
          // A project with none recorded reads the official catalog: adding
          // a source adds to it, never replaces it.
          final current = lock.sources.isNotEmpty
              ? lock.sources
              : [
                  LockedSource(
                    SourceConfig.officialId,
                    SourceConfig.official.url,
                  ),
                ];
          final clash = current.where(
            (s) => s.id == adding!.id && s.url != adding.url,
          );
          if (clash.isNotEmpty) {
            throw CommandFailure(
              'The catalog at ${adding.url} calls itself "${adding.id}", as '
              '${clash.first.url} does. Remove that one first if this one '
              'replaces it.',
            );
          }
          next = StoreLock(
            sources: current,
            items: lock.items,
            generator: lock.generator,
          ).withSource(adding);
        } else {
          final keep = [
            for (final s in lock.sources)
              if (s.id != target && s.url != target) s,
          ];
          if (keep.length == lock.sources.length) {
            throw CommandFailure('No source "$target" in this project.');
          }
          next = StoreLock(
            sources: keep,
            items: lock.items,
            generator: lock.generator,
          );
        }
        project.writeLock(next);
        return next;
      }),
    );
    output.line(
      adding != null
          ? 'Added ${adding.id} ($items items).'
          : 'Removed $target.',
    );
    output.result = [for (final s in next.sources) s.toJson()];
    return 0;
  }
}

/// `just store cache [clean]`.
final class CacheCommand extends StoreProjectCommand {
  /// Shows or clears the per-user download cache (--cache names another).
  CacheCommand() : super(catalogs: false, cache: true);

  @override
  String get name => 'cache';

  @override
  String get description =>
      'Show where downloads are kept and how much room they take; '
      '`cache clean` empties it.';

  @override
  String get invocation => '${context.invokedAs} store cache [clean]';

  @override
  Future<int> run() async {
    final dir = cacheDir;
    if (dir == null) {
      throw const CommandFailure('There is no home folder for a cache.');
    }
    final cache = DownloadCache(dir);
    if (rest.isEmpty) {
      final size = cache.sizeInBytes;
      output
        ..result = {'dir': dir, 'bytes': size}
        ..line('$dir  ${_size(size)}');
      return 0;
    }
    if (rest.length != 1 || rest.single != 'clean') {
      throw const UsageFailure('Use: cache, or cache clean.');
    }
    final size = cache.sizeInBytes;
    if (size > 0 && !confirm('Delete ${_size(size)} of downloads in $dir?')) {
      return 1;
    }
    cache.clear();
    output
      ..result = {'dir': dir, 'freed': size}
      ..line('Freed ${_size(size)}.');
    return 0;
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// [path] made absolute against [cwd].
String absoluteIn(String path, String cwd) =>
    File(path).isAbsolute ? path : '$cwd/$path';

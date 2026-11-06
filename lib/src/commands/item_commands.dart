/// `just store install`, `update`, `uninstall`, `list`, `search` and
/// `info`: the commands about items.
library;

import 'package:just_core_cli/just_core_cli.dart';
import 'package:meta/meta.dart';

import '../catalog/item_traits.dart';
import '../install/item_source.dart';
import '../sources/store_source.dart';
import '../store/asset_store.dart';
import 'store_project_command.dart';

/// `just store install <id>[@<version>]` (and `just add`).
@internal
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
@internal
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
@internal
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
@internal
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
@internal
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
@internal
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

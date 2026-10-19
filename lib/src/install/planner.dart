/// Working out what an install, update or uninstall would change, and
/// whether it can, before anything is touched.
library;

import 'dart:io';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/semver.dart';
import '../catalog/store_index.dart';
import '../project/lockfile.dart';
import '../project/overrides_target.dart';
import '../project/package_info.dart';
import '../project/pubspec_editor.dart';
import '../project/reference_scan.dart';
import '../project/store_project.dart';
import '../sources/store_source.dart';

/// An item as one source offers it.
final class CatalogEntry {
  /// [item] from the source [sourceId].
  const CatalogEntry(this.sourceId, this.item, {this.source});

  /// The source's id, as the lockfile records it.
  final String sourceId;

  /// Where to download from; null in tests that only plan.
  final StoreSource? source;

  /// The item.
  final StoreItem item;
}

/// Every enabled source's catalog, merged. When two sources list the same
/// id, the first source wins and the clash is reported.
final class StoreCatalog {
  /// The catalogs, in priority order.
  StoreCatalog(List<(String, StoreSource?, StoreIndex)> catalogs) {
    for (final (sourceId, source, index) in catalogs) {
      for (final item in index.items) {
        final existing = _entries[item.id];
        if (existing != null) {
          clashes.add(
            '"${item.id}" is in both ${existing.sourceId} and $sourceId; '
            'the store uses ${existing.sourceId}.',
          );
          continue;
        }
        _entries[item.id] = CatalogEntry(sourceId, item, source: source);
      }
      for (final c in index.categories) {
        _categories.putIfAbsent(c.id, () => c);
      }
    }
  }

  final Map<String, CatalogEntry> _entries = {};
  final Map<String, StoreCategory> _categories = {};

  /// Ids two sources both list.
  final List<String> clashes = [];

  /// The entry for [id], or null.
  CatalogEntry? entry(String id) => _entries[id];

  /// Every entry.
  Iterable<CatalogEntry> get entries => _entries.values;

  /// Every category, sorted.
  List<StoreCategory> get categories =>
      _categories.values.toList()..sort((a, b) => a.order.compareTo(b.order));
}

/// What a project has now, as the planner needs it.
final class ProjectState {
  /// A project with [lock] installed.
  const ProjectState({
    required this.lock,
    this.manifests = const {},
    this.foreignOverrides = const {},
    this.graph,
    this.environment = const {},
    this.existingFolders = const {},
  });

  /// Reads [project]'s state; [target] says which overrides file is live.
  static ProjectState read(StoreProject project, OverridesTarget target) {
    final lock = project.readLock();
    final manifests = <String, ItemManifest>{};
    for (final e in lock.items.entries) {
      final path = e.value.path;
      if (path == null) continue;
      final file = project.file('$path/${ItemManifest.fileName}');
      if (!file.existsSync()) continue;
      try {
        manifests[e.key] = ItemManifest.parse(file.readAsStringSync());
      } on StoreFormatException {
        // A damaged manifest: the item is still listed, just not checked.
      }
    }
    final foreign = <String, DependencySpec>{};
    final overrides = project.file(target.active);
    if (overrides.existsSync()) {
      try {
        foreign.addAll(
          PubspecEditor.parse(
            overrides.readAsStringSync(),
            marker: storeBlock,
          ).unmanaged('dependency_overrides'),
        );
      } on PubspecEditException {
        // Reported when the install tries to edit it.
      }
    }
    final graph = PackageGraph.read(project.root);
    final config = PackageConfig.read(project.root);
    final env = <String, Version>{};
    for (final name in const ['just_game_engine', 'just_game_engine_editor']) {
      final v = graph?.versionOf(name);
      if (v != null) env[name] = v;
    }
    final flutter = Version.tryParse(config?.flutterVersion ?? '');
    if (flutter != null) env['flutter'] = flutter;
    final root = config?.flutterRoot;
    if (root != null) {
      final file = File('$root/bin/cache/dart-sdk/version');
      final dart = file.existsSync()
          ? Version.tryParse(file.readAsStringSync().trim())
          : null;
      if (dart != null) env['sdk'] = dart;
    }
    final folders = <String>{};
    final packages = project.dir(StoreProject.packagesDir);
    if (packages.existsSync()) {
      for (final category in packages.listSync().whereType<Directory>()) {
        for (final pkg in category.listSync().whereType<Directory>()) {
          final rel = project.relativeOf(pkg.path);
          if (rel != null) folders.add(rel);
        }
      }
    }
    return ProjectState(
      lock: lock,
      manifests: manifests,
      foreignOverrides: foreign,
      graph: graph,
      environment: env,
      existingFolders: folders,
    );
  }

  /// The lockfile.
  final StoreLock lock;

  /// Installed items' manifests, by id.
  final Map<String, ItemManifest> manifests;

  /// Overrides in the live file that the store doesn't manage: developer
  /// checkouts, melos's links.
  final Map<String, DependencySpec> foreignOverrides;

  /// What pub resolved last.
  final PackageGraph? graph;

  /// The versions `requires` is checked against: `sdk` (Dart), `flutter`,
  /// `just_game_engine`, `just_game_engine_editor`.
  final Map<String, Version> environment;

  /// The `packages/{category}/{name}` folders that exist.
  final Set<String> existingFolders;

  /// What the installed item [id] needs from other store items.
  Map<String, VersionConstraint> dependenciesOf(String id) =>
      manifests[id]?.dependencies ?? const {};

  /// The installed version of [id], when the store knows it.
  Version? installedVersion(String id) {
    final item = lock.items[id];
    if (item == null || item.origin == ItemOrigin.hosted) return null;
    return Version.tryParse(item.version) ??
        manifests[id]?.version ??
        graph?.versionOf(id);
  }
}

/// What a plan does to one item.
enum ChangeKind {
  /// Not installed yet.
  install,

  /// Installed; another version replaces it.
  update,

  /// Taken out of the project.
  remove,
}

/// One item a plan changes.
final class PlannedChange {
  /// [kind] for [id].
  const PlannedChange({
    required this.id,
    required this.kind,
    required this.itemKind,
    required this.reason,
    this.entry,
    this.version,
    this.current,
    this.direct = true,
  });

  /// The item's id.
  final String id;

  /// What happens to it.
  final ChangeKind kind;

  /// What it is.
  final ItemKind itemKind;

  /// Why: "you asked", "needed by …", "no longer needed".
  final String reason;

  /// Where it comes from, for installs and updates.
  final CatalogEntry? entry;

  /// The version going in, for installs and updates.
  final StoreItemVersion? version;

  /// What is installed now, for updates and removals.
  final LockedItem? current;

  /// Installed on purpose rather than as another item's dependency.
  final bool direct;

  /// The item's display name.
  String get name => entry?.item.name ?? id;

  /// The folder it goes in (vendored items).
  String? get path {
    final category = entry?.item.category ?? current?.category;
    if (!itemKind.isVendored || category == null) return current?.path;
    return StoreProject.packagePath(category, id);
  }
}

/// How much an issue matters.
enum IssueLevel {
  /// The plan cannot be applied.
  blocker,

  /// Applying it is allowed, after the user has seen this.
  warning,

  /// Worth knowing.
  info,
}

/// Something about a plan the user should see.
final class PlanIssue {
  /// [message] at [level], about item [id].
  const PlanIssue(this.level, this.message, {this.id});

  /// How much it matters.
  final IssueLevel level;

  /// What, in a sentence or two.
  final String message;

  /// The item it concerns.
  final String? id;

  @override
  String toString() => '${level.name}: $message';
}

/// What an install, update or uninstall would do: shown in the preview,
/// then handed to the installer.
final class InstallPlan {
  /// [changes] with [issues].
  const InstallPlan(this.changes, this.issues);

  /// The items it changes.
  final List<PlannedChange> changes;

  /// What the user should know, blockers first.
  final List<PlanIssue> issues;

  /// Whether it can be applied: no blockers, something to do.
  bool get canApply =>
      changes.isNotEmpty && !issues.any((i) => i.level == IssueLevel.blocker);

  /// The blockers.
  Iterable<PlanIssue> get blockers =>
      issues.where((i) => i.level == IssueLevel.blocker);

  /// Whether the editor must restart afterwards: code changes.
  bool get needsRestart => changes.any((c) => c.itemKind.needsRestart);

  /// The bytes to download (archives not cached may be fewer).
  int get downloadBytes =>
      changes.fold(0, (sum, c) => sum + (c.version?.archive?.size ?? 0));
}

/// Plans changes to a project from its [state] and the [catalog].
final class Planner {
  /// A planner for [state], offering what [catalog] lists.
  Planner(this.catalog, this.state);

  /// What sources offer.
  final StoreCatalog catalog;

  /// What the project has.
  final ProjectState state;

  /// Installs [id] — [version], or the newest that fits — with what it
  /// needs.
  InstallPlan install(String id, {Version? version}) => _resolve({
    id: version == null
        ? VersionConstraint.any
        : VersionConstraint.exactly(version),
  });

  /// Updates [id] to the newest version that fits the items needing it.
  InstallPlan update(String id) => _resolve({id: VersionConstraint.any});

  /// Updates every item installed on purpose.
  InstallPlan updateAll() => _resolve({
    for (final e in state.lock.items.entries)
      if (e.value.direct &&
          e.value.origin == ItemOrigin.vendored &&
          catalog.entry(e.key) != null)
        e.key: VersionConstraint.any,
  });

  /// The newest version of [id] a plain update would pick, when newer than
  /// what is installed.
  StoreItemVersion? availableUpdate(String id) {
    final installed = state.installedVersion(id);
    final latest = catalog.entry(id)?.item.latest;
    if (installed == null || latest == null) return null;
    return latest.version > installed ? latest : null;
  }

  /// Removes [id], and the dependencies only it needed. [references] (from
  /// [ReferenceScan]) are what still use it.
  InstallPlan uninstall(
    String id, {
    List<PackageReference> references = const [],
  }) {
    final issues = <PlanIssue>[];
    final locked = state.lock.items[id];
    if (locked == null) {
      return InstallPlan(const [], [
        PlanIssue(IssueLevel.blocker, '"$id" is not installed.', id: id),
      ]);
    }
    if (locked.system) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${_name(id)} is part of the editor and cannot be uninstalled.',
          id: id,
        ),
      );
    }
    if (locked.origin == ItemOrigin.linked) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${_name(id)} comes from your own checkout (${locked.path}); remove '
          'it from your overrides instead.',
          id: id,
        ),
      );
    }
    final needing = [
      for (final other in state.lock.items.keys)
        if (other != id && state.dependenciesOf(other).containsKey(id))
          _name(other),
    ];
    if (needing.isNotEmpty) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${needing.join(', ')} ${needing.length == 1 ? 'needs' : 'need'} '
          '${_name(id)}. Uninstall ${needing.length == 1 ? 'it' : 'them'} '
          'first.',
          id: id,
        ),
      );
    }
    final code = references.where((r) => r.kind == ReferenceKind.code);
    if (code.isNotEmpty) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          'Your code still imports it: '
          '${code.map((r) => '${r.file}:${r.line}').join(', ')}. Remove those '
          'imports first.',
          id: id,
        ),
      );
    }
    final assets = references.where((r) => r.kind != ReferenceKind.code);
    if (assets.isNotEmpty) {
      final files = assets.map((r) => r.file).toSet().toList()..sort();
      issues.add(
        PlanIssue(
          IssueLevel.warning,
          'These files still use it and will show missing assets or '
          'unknown components: ${files.join(', ')}.',
          id: id,
        ),
      );
    }

    final changes = [
      PlannedChange(
        id: id,
        kind: ChangeKind.remove,
        itemKind: locked.kind,
        reason: 'You asked',
        current: locked,
        entry: catalog.entry(id),
      ),
    ];
    // Dependencies installed only for this item, and now needed by nothing.
    final removed = {id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in state.lock.items.entries) {
        if (removed.contains(e.key) || e.value.direct || e.value.system) {
          continue;
        }
        if (e.value.origin == ItemOrigin.linked) continue;
        final stillNeeded = state.lock.items.keys.any(
          (other) =>
              !removed.contains(other) &&
              state.dependenciesOf(other).containsKey(e.key),
        );
        if (!stillNeeded) {
          removed.add(e.key);
          grew = true;
          changes.add(
            PlannedChange(
              id: e.key,
              kind: ChangeKind.remove,
              itemKind: e.value.kind,
              reason: 'No longer needed',
              current: e.value,
              direct: false,
              entry: catalog.entry(e.key),
            ),
          );
        }
      }
    }
    issues.sort((a, b) => a.level.index.compareTo(b.level.index));
    return InstallPlan(changes, issues);
  }

  // ---------------------------------------------------------------------

  InstallPlan _resolve(Map<String, VersionConstraint> targets) {
    final issues = <PlanIssue>[];
    final wants = <String, List<(VersionConstraint, String)>>{};
    final chosen = <String, StoreItemVersion>{};
    final queue = <String>[];

    void want(String id, VersionConstraint c, String by) {
      (wants[id] ??= []).add((c, by));
      queue.add(id);
    }

    for (final e in targets.entries) {
      want(e.key, e.value, 'you');
    }
    // What installed items need from anything this plan may change.
    for (final other in state.lock.items.keys) {
      if (targets.containsKey(other)) continue;
      state.dependenciesOf(other).forEach((dep, c) {
        (wants[dep] ??= []).add((c, _name(other)));
      });
    }

    var steps = 0;
    while (queue.isNotEmpty) {
      if (++steps > 2000) {
        issues.add(
          const PlanIssue(
            IssueLevel.blocker,
            'The items depend on each other in a way the store cannot '
            'settle.',
          ),
        );
        break;
      }
      final id = queue.removeAt(0);
      final constraints = wants[id]!;
      final locked = state.lock.items[id];
      final isTarget = targets.containsKey(id);

      // A developer's own checkout stays as it is.
      if (locked?.origin == ItemOrigin.linked ||
          (locked == null && state.foreignOverrides.containsKey(id))) {
        if (isTarget) {
          issues.add(
            PlanIssue(
              IssueLevel.blocker,
              '${_name(id)} comes from your own checkout; update it there.',
              id: id,
            ),
          );
        }
        continue;
      }

      // Installed and good enough: leave it.
      final installed = state.installedVersion(id);
      if (!isTarget &&
          installed != null &&
          constraints.every((c) => c.$1.allows(installed))) {
        continue;
      }

      final entry = catalog.entry(id);
      if (entry == null) {
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            '"$id" (needed by ${constraints.map((c) => c.$2).join(', ')}) is '
            'not in any of your sources.',
            id: id,
          ),
        );
        continue;
      }
      final item = entry.item;
      if (item.kind == ItemKind.template) {
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            '${item.name} is a project template, not something to install: '
            'start a project from it with `just create <folder> --template '
            '${item.id}`.',
            id: id,
          ),
        );
        continue;
      }
      if (item.unavailable) {
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            '${item.name} is no longer offered: its repository was removed '
            'or changed hands.',
            id: id,
          ),
        );
        continue;
      }
      final candidates = item.available
          .where((v) => constraints.every((c) => c.$1.allows(v.version)))
          .map((v) => v.version);
      final pickVersion = VersionConstraint.any.bestOf(candidates);
      if (pickVersion == null) {
        final why = constraints.map((c) => '${c.$2} needs ${c.$1}').join('; ');
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            'No version of ${item.name} fits: $why. Available: '
            '${item.available.map((v) => v.version).join(', ')}.',
            id: id,
          ),
        );
        continue;
      }
      final pick = item.versionOf(pickVersion)!;
      if (chosen[id]?.version == pick.version) continue;
      chosen[id] = pick;
      pick.dependencies.forEach((dep, c) => want(dep, c, item.name));
    }

    final changes = <PlannedChange>[];
    for (final e in chosen.entries) {
      final id = e.key;
      final entry = catalog.entry(id)!;
      final item = entry.item;
      final v = e.value;
      final locked = state.lock.items[id];
      final installed = state.installedVersion(id);
      if (installed != null && installed == v.version) {
        if (targets.containsKey(id)) {
          issues.add(
            PlanIssue(
              IssueLevel.info,
              '${item.name} ${v.version} is already installed.',
              id: id,
            ),
          );
        }
        continue;
      }
      if (locked?.origin == ItemOrigin.hosted &&
          locked!.version == '${v.pubConstraint ?? '^${v.version}'}') {
        continue;
      }
      changes.add(
        PlannedChange(
          id: id,
          kind: locked == null ? ChangeKind.install : ChangeKind.update,
          itemKind: item.kind,
          reason: targets.containsKey(id)
              ? 'You asked'
              : 'Needed by ${wants[id]!.map((c) => c.$2).toSet().join(', ')}',
          entry: entry,
          version: v,
          current: locked,
          direct: targets.containsKey(id) || (locked?.direct ?? false),
        ),
      );
      _checkChange(id, item, v, locked, issues);
    }
    for (final c in catalog.clashes) {
      issues.add(PlanIssue(IssueLevel.info, c));
    }
    issues.sort((a, b) => a.level.index.compareTo(b.level.index));
    changes.sort((a, b) => a.id.compareTo(b.id));
    return InstallPlan(changes, issues);
  }

  void _checkChange(
    String id,
    StoreItem item,
    StoreItemVersion v,
    LockedItem? locked,
    List<PlanIssue> issues,
  ) {
    if (v.access == AccessLevel.entitled) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is a paid item. Paid items are not available in this '
          'version of the Asset Store yet.',
          id: id,
        ),
      );
    }
    v.requires.forEach((name, constraint) {
      final have = state.environment[name];
      if (have != null && !constraint.allows(have)) {
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            '${item.name} ${v.version} needs ${_requirement(name)} '
            '$constraint; this project has $have.',
            id: id,
          ),
        );
      }
    });
    if (locked == null) {
      final graphHasIt = state.graph?.nodes.containsKey(id) ?? false;
      if (graphHasIt && !state.foreignOverrides.containsKey(id)) {
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            'This project already uses a package named "$id" that the store '
            'did not install. Installing ${item.name} would replace it.',
            id: id,
          ),
        );
      }
      if (item.kind.isVendored) {
        final path = StoreProject.packagePath(item.category, id);
        if (state.existingFolders.contains(path)) {
          issues.add(
            PlanIssue(
              IssueLevel.blocker,
              '$path already exists, and the store did not put it there. Move '
              'it away first.',
              id: id,
            ),
          );
        }
      }
    }
    if (v.nativePlugins.isNotEmpty) {
      issues.add(
        PlanIssue(
          IssueLevel.warning,
          item.kind == ItemKind.editorExtension
              ? '${item.name} brings native plugins '
                    '(${v.nativePlugins.join(', ')}). It installs as a dev '
                    'dependency, so release builds leave them out.'
              : '${item.name} brings native plugins '
                    '(${v.nativePlugins.join(', ')}) that build into every '
                    'version of the game.',
          id: id,
        ),
      );
    }
    if (item.trust != TrustLevel.official) {
      issues.add(
        PlanIssue(
          item.kind.isCode ? IssueLevel.warning : IssueLevel.info,
          item.kind.isCode
              ? '${item.name} is code from ${item.author?.name ?? item.publisher} '
                    '(${item.trust.name}). It will run with your permissions '
                    'in the editor and the game: install it only if you trust '
                    'its publisher.'
              : '${item.name} is from ${item.author?.name ?? item.publisher} '
                    '(${item.trust.name}).',
          id: id,
        ),
      );
    }
    final attribution = item.license?.attribution;
    if (attribution != null) {
      issues.add(
        PlanIssue(
          IssueLevel.info,
          '${item.name}\'s licence (${item.license!.spdx}) asks you to credit: '
          '$attribution',
          id: id,
        ),
      );
    }
  }

  String _name(String id) =>
      catalog.entry(id)?.item.name ?? state.manifests[id]?.name ?? id;

  static String _requirement(String key) => switch (key) {
    'sdk' => 'Dart',
    'flutter' => 'Flutter',
    _ => key,
  };
}

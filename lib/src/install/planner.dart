/// Working out what an install, update or uninstall would change, and
/// whether it can, before anything is touched.
library;

import 'dart:io';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/names.dart';
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
///
/// How far the store vouches for an item ([StoreItem.trust]) is what its
/// catalog says only when that catalog may say it: the official catalog,
/// a catalog in a folder on this machine (one being built or tried out),
/// or one made in memory. Every other catalog's items are community items,
/// whatever it claims.
final class StoreCatalog {
  /// The catalogs, in priority order.
  StoreCatalog(List<(String, StoreSource?, StoreIndex)> catalogs) {
    for (final (sourceId, source, index) in catalogs) {
      final vouches = _vouches(source);
      for (var item in index.items) {
        final existing = _entries[item.id];
        if (existing != null) {
          clashes.add(
            '"${item.id}" is in both ${existing.sourceId} and $sourceId; '
            'the store uses ${existing.sourceId}.',
          );
          continue;
        }
        if (!vouches && item.trust != TrustLevel.community) {
          item = item.withTrust(TrustLevel.community);
        }
        _entries[item.id] = CatalogEntry(sourceId, item, source: source);
      }
      for (final c in index.categories) {
        _categories.putIfAbsent(c.id, () => c);
      }
      for (final r in index.removed) {
        _removedBy['$sourceId/${r.id}'] = r;
        if (vouches) _removedVouched.putIfAbsent(r.id, () => r);
      }
    }
  }

  final Map<String, CatalogEntry> _entries = {};
  final Map<String, StoreCategory> _categories = {};
  final Map<String, RemovedItem> _removedBy = {};
  final Map<String, RemovedItem> _removedVouched = {};

  /// Why the store took down the item [id], when it did: as the catalog it
  /// was installed from ([source]) says, or a catalog that may vouch for
  /// items (the official one, a folder on this machine). Another catalog
  /// can't take down what it didn't provide.
  RemovedItem? removal(String id, {String? source}) =>
      (source == null ? null : _removedBy['$source/$id']) ??
      _removedVouched[id];

  /// Ids two sources both list.
  final List<String> clashes = [];

  /// The entry for [id], or null.
  CatalogEntry? entry(String id) => _entries[id];

  /// Every entry.
  Iterable<CatalogEntry> get entries => _entries.values;

  /// Every category, sorted.
  List<StoreCategory> get categories =>
      _categories.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  /// Whether [source]'s catalog may say how far the store vouches for its
  /// items: the official catalog, one made in memory, or one in a folder on
  /// this machine (never on another machine's share).
  static bool _vouches(StoreSource? source) {
    if (source == null) return true;
    final uri = source.indexUri;
    return (uri.scheme == 'file' && uri.host.isEmpty) ||
        uri.scheme == 'memory' ||
        '$uri' == SourceConfig.official.url;
  }
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
    for (final root in StoreProject.itemRoots) {
      final dir = project.dir(root);
      if (!dir.existsSync()) continue;
      for (final category in dir.listSync().whereType<Directory>()) {
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

  /// The `packages/{category}/{name}` and `plugins/{category}/{name}`
  /// folders that exist ([StoreProject.itemRoots]).
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

  /// Installed already, as another item's dependency, and now on purpose
  /// too: it joins the project's own dependencies, so it stays when what
  /// needed it goes. Nothing is downloaded or replaced.
  adopt,
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

  /// What is installed now, for updates, removals and adoptions.
  final LockedItem? current;

  /// Installed on purpose rather than as another item's dependency.
  final bool direct;

  /// The item's display name.
  String get name => entry?.item.name ?? id;

  /// The folder it goes in (vendored items): `plugins/{category}/{id}` for
  /// an editor extension or a kit, `packages/{category}/{id}` for content.
  String? get path {
    final category = entry?.item.category ?? current?.category;
    if (!itemKind.isVendored || category == null) return current?.path;
    return StoreProject.itemPath(itemKind, category, id);
  }

  /// Whether new code comes in or goes: the editor restarts to load it.
  bool get needsRestart => kind != ChangeKind.adopt && itemKind.needsRestart;
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
  /// [changes] with [issues], worked out from [catalog].
  const InstallPlan(this.changes, this.issues, {this.catalog});

  /// The items it changes.
  final List<PlannedChange> changes;

  /// What the user should know, blockers first.
  final List<PlanIssue> issues;

  /// The catalog it was planned from, when a [Planner] made it: the
  /// installer checks each package against it (a package must not depend
  /// on a store item it doesn't declare).
  final StoreCatalog? catalog;

  /// Whether it can be applied: no blockers, something to do.
  bool get canApply =>
      changes.isNotEmpty && !issues.any((i) => i.level == IssueLevel.blocker);

  /// The blockers.
  Iterable<PlanIssue> get blockers =>
      issues.where((i) => i.level == IssueLevel.blocker);

  /// Whether the editor must restart afterwards: code changes.
  bool get needsRestart => changes.any((c) => c.needsRestart);

  /// The bytes to download (archives not cached may be fewer).
  int get downloadBytes => changes.fold(
    0,
    (sum, c) =>
        sum +
        (c.kind == ChangeKind.adopt || c.kind == ChangeKind.remove
            ? 0
            : c.version?.archive?.size ?? 0),
  );
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
  /// needs. One installed already as another item's dependency becomes
  /// one of the project's own ([ChangeKind.adopt]).
  InstallPlan install(String id, {Version? version}) => _resolve({
    id: version == null
        ? VersionConstraint.any
        : VersionConstraint.exactly(version),
  });

  /// Installs every item in [wanted], each at the newest version its
  /// constraint and the rest allow, in one plan: what a project template
  /// needs, say.
  InstallPlan installAll(Map<String, VersionConstraint> wanted) =>
      _resolve(wanted);

  /// Updates [id] to the newest version that fits the items needing it:
  /// never to one older than is installed. Nothing to do when nothing newer
  /// is available.
  InstallPlan update(String id) {
    final locked = state.lock.items[id];
    if (locked == null) {
      return _finish(const [], [
        PlanIssue(
          IssueLevel.blocker,
          '"$id" is not installed: install it instead.',
          id: id,
        ),
      ]);
    }
    final installed = state.installedVersion(id);
    // A pub.dev library takes the newest constraint; a checkout says it is
    // updated where it lives.
    if (locked.origin != ItemOrigin.vendored ||
        installed == null ||
        catalog.entry(id) == null) {
      return _resolve({id: VersionConstraint.any});
    }
    if (_newerThanInstalled(id) == null) {
      final withdrawn = catalog.entry(id)?.item.unavailable ?? false;
      return _finish(const [], [
        PlanIssue(
          IssueLevel.info,
          withdrawn
              ? '${_name(id)} is no longer offered; $installed stays.'
              : '${_name(id)} $installed is the newest available.',
          id: id,
        ),
      ]);
    }
    return _resolve({id: _floor(installed)});
  }

  /// Updates every item installed on purpose that has a newer version.
  /// Items no longer offered stay as they are, and say so.
  InstallPlan updateAll() {
    final targets = <String, VersionConstraint>{};
    final notes = <PlanIssue>[];
    for (final e in state.lock.items.entries) {
      final item = catalog.entry(e.key)?.item;
      final installed = state.installedVersion(e.key);
      if (!e.value.direct ||
          e.value.origin != ItemOrigin.vendored ||
          item == null ||
          installed == null) {
        continue;
      }
      if (item.unavailable) {
        notes.add(
          PlanIssue(
            IssueLevel.info,
            '${item.name} is no longer offered; $installed stays.',
            id: e.key,
          ),
        );
        continue;
      }
      if (_newerThanInstalled(e.key) != null) {
        targets[e.key] = _floor(installed);
      }
    }
    if (targets.isEmpty) return _finish(const [], notes);
    final plan = _resolve(targets);
    return _finish(plan.changes, [...plan.issues, ...notes]);
  }

  /// The newest available version of the installed [id] that is newer
  /// than what is installed, or null.
  Version? _newerThanInstalled(String id) {
    final installed = state.installedVersion(id);
    final item = catalog.entry(id)?.item;
    if (installed == null || item == null || item.unavailable) return null;
    return _floor(installed).bestOf([
      for (final v in item.available)
        if (v.version > installed) v.version,
    ]);
  }

  /// [installed] or newer.
  static VersionConstraint _floor(Version installed) =>
      VersionConstraint.parse('>=$installed');

  /// The newest version of [id] a plain update would pick, when newer than
  /// what is installed.
  StoreItemVersion? availableUpdate(String id) {
    final installed = state.installedVersion(id);
    final latest = catalog.entry(id)?.item.latest;
    if (installed == null || latest == null) return null;
    return latest.version > installed ? latest : null;
  }

  /// The installed items the store took down (malware, a stolen asset), and
  /// those whose installed version its catalog has since taken down (a
  /// licence problem, say), each as a warning.
  List<PlanIssue> takedowns() => [
    for (final MapEntry(key: id, value: locked) in state.lock.items.entries)
      if (catalog.removal(id, source: locked.source) case final r?)
        PlanIssue(
          IssueLevel.warning,
          '${_name(id)} was taken down by the store: ${r.reason} Uninstall '
          'it.',
          id: id,
        )
      else if (_takenDown(id) case final v?)
        PlanIssue(
          IssueLevel.warning,
          '${_name(id)} ${v.version} was taken down by its catalog: update '
          'it, or uninstall it.',
          id: id,
        ),
  ];

  StoreItemVersion? _takenDown(String id) {
    final installed = state.installedVersion(id);
    if (installed == null) return null;
    final v = catalog.entry(id)?.item.versionOf(installed);
    return v != null && v.blocked ? v : null;
  }

  /// Removes [id], and the dependencies only it needed. [references] (from
  /// [ReferenceScan]) are what still use it.
  ///
  /// [referencesOf] finds what uses one of those dependencies, the folders
  /// of the items going (the set it is given) left out: code that imports
  /// one blocks the plan, as code importing [id] does.
  InstallPlan uninstall(
    String id, {
    List<PackageReference> references = const [],
    List<PackageReference> Function(String id, Set<String> going)? referencesOf,
  }) {
    final issues = <PlanIssue>[];
    final locked = state.lock.items[id];
    if (locked == null) {
      return _finish(const [], [
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
          '${_name(id)} comes from your own checkout (${locked.path}): unlink '
          'it instead (`store unlink $id`), which leaves the checkout as it '
          'is.',
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
    // What still needs it, among what stays: items that need each other go
    // together.
    final needing = [
      for (final other in state.lock.items.keys)
        if (!removed.contains(other) &&
            state.dependenciesOf(other).containsKey(id))
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
    if (referencesOf != null) {
      for (final c in changes) {
        if (c.id == id) continue;
        final code = [
          for (final r in referencesOf(c.id, removed))
            if (r.kind == ReferenceKind.code) '${r.file}:${r.line}',
        ];
        if (code.isEmpty) continue;
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            'Your code imports ${c.name}, which would go too, as nothing else '
            'needs it: ${code.join(', ')}. Remove those imports, or install '
            '${c.name} on purpose first (`store install ${c.id}`).',
            id: c.id,
          ),
        );
      }
    }
    return _finish(changes, issues);
  }

  // ---------------------------------------------------------------------

  /// [changes] and [issues] as a plan: with the takedowns of what the plan
  /// leaves in place, blockers first.
  InstallPlan _finish(List<PlannedChange> changes, List<PlanIssue> issues) {
    final changed = {for (final c in changes) c.id};
    final all = [
      ...issues,
      for (final t in takedowns())
        if (!changed.contains(t.id)) t,
    ]..sort((a, b) => a.level.index.compareTo(b.level.index));
    return InstallPlan(changes, all, catalog: catalog);
  }

  InstallPlan _resolve(Map<String, VersionConstraint> targets) {
    final resolver = _Resolver(this, targets);
    final decided = resolver.solve();
    final issues = <PlanIssue>[];
    final changes = <PlannedChange>[];
    if (decided == null) {
      issues.add(resolver.failure);
    } else {
      for (final MapEntry(key: id, value: v) in decided.entries) {
        if (v == null) continue; // Kept as it is.
        final entry = catalog.entry(id)!;
        final item = entry.item;
        final locked = state.lock.items[id];
        final installed = state.installedVersion(id);
        final isTarget = targets.containsKey(id);
        final unchanged =
            (installed != null && installed == v.version) ||
            (locked?.origin == ItemOrigin.hosted &&
                locked!.version == '${v.pubConstraint ?? '^${v.version}'}');
        if (unchanged) {
          if (isTarget && locked != null && !locked.direct) {
            changes.add(
              PlannedChange(
                id: id,
                kind: ChangeKind.adopt,
                itemKind: item.kind,
                reason:
                    'You asked; it was there for '
                    '${_needers(id).join(', ')}',
                entry: entry,
                version: v,
                current: locked,
              ),
            );
          } else if (isTarget) {
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
        final change = PlannedChange(
          id: id,
          kind: locked == null ? ChangeKind.install : ChangeKind.update,
          itemKind: item.kind,
          reason: isTarget
              ? 'You asked'
              : 'Needed by ${resolver.neededBy(id).join(', ')}',
          entry: entry,
          version: v,
          current: locked,
          direct: isTarget || (locked?.direct ?? false),
        );
        changes.add(change);
        _checkChange(change, issues);
      }
    }
    _checkReplaced(changes, issues);
    for (final c in catalog.clashes) {
      issues.add(PlanIssue(IssueLevel.info, c));
    }
    changes.sort((a, b) => a.id.compareTo(b.id));
    return _finish(changes, issues);
  }

  /// The installed items that need [id].
  List<String> _needers(String id) => [
    for (final other in state.lock.items.keys)
      if (other != id && state.dependenciesOf(other).containsKey(id))
        _name(other),
  ];

  /// A vendored item is its package for the whole project: one that
  /// another change in the plan fetches from pub.dev would be replaced by
  /// it there too.
  void _checkReplaced(List<PlannedChange> changes, List<PlanIssue> issues) {
    final vendored = {
      for (final c in changes)
        if (c.entry != null && c.itemKind.isVendored) c.id: c.entry!.item,
    };
    for (final c in changes) {
      final v = c.version;
      if (v == null || c.entry == null) continue;
      for (final name in v.pubDependencies.keys) {
        final item = vendored[name];
        if (item == null) continue;
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            '${_name(c.id)} needs the package "$name" from pub.dev, and '
            '${item.name} would take its place.',
            id: name,
          ),
        );
      }
    }
  }

  void _checkChange(PlannedChange change, List<PlanIssue> issues) {
    final id = change.id;
    final item = change.entry!.item;
    final v = change.version!;
    if (!item.isOfficial && ReservedNames.isReserved(id)) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is called "$id", a name only the store\'s own team '
          'gives its items, yet it comes from '
          '${item.author?.name ?? item.publisher} (${item.trust.name}).',
          id: id,
        ),
      );
    }
    final size = v.archive?.size ?? 0;
    if (size > StoreArchive.maxSize) {
      issues.add(
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} ${v.version} is ${(size / (1 << 20)).ceil()} MiB; '
          'the store installs archives of up to '
          '${StoreArchive.maxSize >> 20} MiB.',
          id: id,
        ),
      );
    }
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
    if (change.current == null) {
      if (state.graph == null && !item.isOfficial && item.kind.isVendored) {
        // Without it the store can't tell whether the project already
        // gets a package of this name from somewhere else.
        issues.add(
          PlanIssue(
            IssueLevel.blocker,
            'Run pub get in this project first: the store checks the '
            'packages it already uses before adding ${item.name}.',
            id: id,
          ),
        );
      }
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
        final path = StoreProject.itemPath(item.kind, item.category, id);
        final taken = _folderTaken(item.category, id);
        if (taken != null) {
          // The same folder in the other root would be a second copy of the
          // package, which pub could take instead.
          final twice = taken.toLowerCase() == path.toLowerCase()
              ? ''
              : '${item.name} goes in $path, so the project would have two '
                    'copies of it. ';
          issues.add(
            PlanIssue(
              IssueLevel.blocker,
              '$taken already exists, and the store did not put it there. '
              '${twice}Move it away first.',
              id: id,
            ),
          );
        }
      }
    }
    // How finished it is: asked about before it comes in.
    switch (v.stage) {
      case ItemStage.experimental:
        issues.add(
          PlanIssue(
            IssueLevel.warning,
            '${item.name} ${v.version} is experimental: it may change or '
            'break between versions.',
            id: id,
          ),
        );
      case ItemStage.deprecated:
        issues.add(
          PlanIssue(
            IssueLevel.warning,
            '${item.name} is deprecated: it is no longer developed.'
            '${v.replacedBy == null ? '' : ' Use ${_name(v.replacedBy!)} instead.'}',
            id: id,
          ),
        );
      case ItemStage.stable || ItemStage.beta || null:
        break;
    }
    // What its code does, as it declares: native code has its own note.
    final declared = {
      ...v.permissions,
    }..remove(v.nativePlugins.isEmpty ? null : ItemPermission.native);
    if (declared.isNotEmpty) {
      issues.add(
        PlanIssue(
          IssueLevel.warning,
          '${item.name} ${ItemPermission.describe(declared)}, as it '
          'declares.',
          id: id,
        ),
      );
    }
    if (v.nativePlugins.isNotEmpty) {
      final plugins = v.nativePlugins.join(', ');
      issues.add(
        PlanIssue(
          IssueLevel.warning,
          item.kind == ItemKind.editorExtension && change.direct
              ? '${item.name} brings native plugins ($plugins). It installs as '
                    'a dev dependency, so release builds leave them out.'
              : item.kind == ItemKind.editorExtension
              ? '${item.name} brings native plugins ($plugins). It comes in as '
                    "a dependency of the game's code, so they build into "
                    'every version of the game.'
              : '${item.name} brings native plugins ($plugins) that build '
                    'into every version of the game.',
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

  /// The existing folder an item [id] of [category] would clash with, when
  /// one exists: `{root}/{category}/{id}` in any of
  /// [StoreProject.itemRoots], not only the one the item goes in — as
  /// written, or (on the file systems that ignore case, Windows's and
  /// macOS's) in another case.
  String? _folderTaken(String category, String id) {
    final caseless = Platform.isWindows || Platform.isMacOS;
    for (final root in StoreProject.itemRoots) {
      final path = '$root/$category/$id';
      for (final f in state.existingFolders) {
        if (f == path || (caseless && f.toLowerCase() == path.toLowerCase())) {
          return f;
        }
      }
    }
    return null;
  }

  String _name(String id) =>
      catalog.entry(id)?.item.name ?? state.manifests[id]?.name ?? id;

  static String _requirement(String key) => switch (key) {
    'sdk' => 'Dart',
    'flutter' => 'Flutter',
    _ => key,
  };
}

/// Picks a version for every item a plan touches, going back on a choice
/// when it leads nowhere.
///
/// What constrains an item: what was asked for ("you"), the installed
/// items the plan keeps (by their manifests), and the versions it picks
/// (by the catalog). An installed item the plan replaces stops
/// constraining anything: its new version speaks for it. Installed items
/// are kept while they fit, and replaced only when they must.
final class _Resolver {
  _Resolver(this.planner, this.targets);

  final Planner planner;
  final Map<String, VersionConstraint> targets;

  /// Each decided item: the catalog version picked, or null to keep what
  /// is installed (or a developer's checkout).
  final Map<String, StoreItemVersion?> decided = {};

  PlanIssue? _failure;
  var _failureDepth = -1;
  var _steps = 0;
  var _gaveUp = false;

  /// How many choices it tries before it says it cannot settle them.
  static const int maxSteps = 20000;

  ProjectState get _state => planner.state;
  StoreCatalog get _catalog => planner.catalog;

  /// Why no plan was found: the problem met deepest into the search.
  PlanIssue get failure => _gaveUp || _failure == null
      ? const PlanIssue(
          IssueLevel.blocker,
          'The items depend on each other in a way the store cannot settle.',
        )
      : _failure!;

  /// Every item's decision, or null when none fits.
  Map<String, StoreItemVersion?>? solve() => _search(0) ? decided : null;

  /// The picked versions that need [id].
  List<String> neededBy(String id) => [
    for (final e in decided.entries)
      if (e.key != id && (e.value?.dependencies.containsKey(id) ?? false))
        planner._name(e.key),
  ];

  /// The items to decide, in the order they come up: what was asked for,
  /// then what the picked versions need.
  List<String> _wanted() {
    final out = [...targets.keys];
    final seen = out.toSet();
    for (final v in decided.values) {
      if (v == null) continue;
      for (final dep in v.dependencies.keys.toList()..sort()) {
        if (seen.add(dep)) out.add(dep);
      }
    }
    return out;
  }

  /// What asks [id] for which versions, and who.
  List<(VersionConstraint, String)> _constraintsOn(String id) {
    final out = <(VersionConstraint, String)>[];
    final target = targets[id];
    if (target != null) out.add((target, 'you'));
    for (final other in _state.lock.items.keys) {
      if (other == id || decided[other] != null) continue;
      final c = _state.dependenciesOf(other)[id];
      if (c != null) out.add((c, planner._name(other)));
    }
    decided.forEach((other, v) {
      if (other == id || v == null) return;
      final c = v.dependencies[id];
      if (c != null) out.add((c, planner._name(other)));
    });
    return out;
  }

  bool _search(int depth) {
    if (++_steps > maxSteps) {
      _gaveUp = true;
      return false;
    }
    final wanted = _wanted();
    // A choice made earlier that what was picked since rules out.
    for (final id in wanted) {
      if (!decided.containsKey(id)) continue;
      final problem = _misfit(id, decided[id], _constraintsOn(id));
      if (problem != null) {
        _fail(depth, problem);
        return false;
      }
    }
    final next = wanted.where((id) => !decided.containsKey(id)).firstOrNull;
    if (next == null) return true;
    final (options, problem) = _options(next, _constraintsOn(next));
    if (options.isEmpty) {
      _fail(depth, problem!);
      return false;
    }
    for (final option in options) {
      decided[next] = option;
      if (_search(depth + 1)) return true;
      decided.remove(next);
      if (_gaveUp) return false;
    }
    return false;
  }

  void _fail(int depth, PlanIssue problem) {
    if (depth > _failureDepth) {
      _failureDepth = depth;
      _failure = problem;
    }
  }

  /// Whether the item kept ([option] null) or picked fails [constraints].
  PlanIssue? _misfit(
    String id,
    StoreItemVersion? option,
    List<(VersionConstraint, String)> constraints,
  ) {
    final Version? version;
    if (option != null) {
      version = option.version;
    } else {
      final locked = _state.lock.items[id];
      // A checkout, or a pub.dev library: pub checks those.
      if (locked == null || locked.origin != ItemOrigin.vendored) return null;
      version = _state.installedVersion(id);
    }
    if (version == null || constraints.every((c) => c.$1.allows(version!))) {
      return null;
    }
    return _noFit(id, constraints);
  }

  /// What [id] may be, best first, or why it may be nothing.
  (List<StoreItemVersion?>, PlanIssue?) _options(
    String id,
    List<(VersionConstraint, String)> constraints,
  ) {
    final locked = _state.lock.items[id];
    final isTarget = targets.containsKey(id);
    final name = planner._name(id);
    // A developer's own checkout stays as it is.
    if (locked?.origin == ItemOrigin.linked ||
        (locked == null && _state.foreignOverrides.containsKey(id))) {
      if (!isTarget) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '$name comes from your own checkout; update it there.',
          id: id,
        ),
      );
    }
    final installed = _state.installedVersion(id);
    final keep =
        locked != null &&
        !isTarget &&
        (locked.origin == ItemOrigin.hosted ||
            (installed != null &&
                constraints.every((c) => c.$1.allows(installed))));
    final entry = _catalog.entry(id);
    if (entry == null) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '"$id" (needed by ${constraints.map((c) => c.$2).join(', ')}) is '
          'not in any of your sources.',
          id: id,
        ),
      );
    }
    final item = entry.item;
    if (item.kind == ItemKind.template) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is a project template, not something to install: '
          'start a project from it with `just create <folder> --template '
          '${item.id}`.',
          id: id,
        ),
      );
    }
    if (item.unavailable) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is no longer offered: its repository was removed '
          'or changed hands.',
          id: id,
        ),
      );
    }
    final versions = [
      for (final v in item.available)
        if (constraints.every((c) => c.$1.allows(v.version)) &&
            !(keep && v.version == installed))
          v,
    ]..sort(_preference);
    final options = <StoreItemVersion?>[if (keep) null, ...versions];
    if (options.isEmpty) return (options, _noFit(id, constraints));
    return (options, null);
  }

  /// Versions this project can run before those it can't, releases before
  /// pre-releases, newest first.
  int _preference(StoreItemVersion a, StoreItemVersion b) {
    final fa = _runsHere(a), fb = _runsHere(b);
    if (fa != fb) return fa ? -1 : 1;
    final pa = a.version.isPreRelease, pb = b.version.isPreRelease;
    if (pa != pb) return pa ? 1 : -1;
    return b.version.compareTo(a.version);
  }

  bool _runsHere(StoreItemVersion v) => v.requires.entries.every((e) {
    final have = _state.environment[e.key];
    return have == null || e.value.allows(have);
  });

  PlanIssue _noFit(String id, List<(VersionConstraint, String)> constraints) {
    final item = _catalog.entry(id)?.item;
    final available = [
      for (final v in item?.available ?? const <StoreItemVersion>[])
        '${v.version}',
    ];
    final why = constraints
        .map(
          (c) =>
              c.$2 == 'you' ? 'you asked for ${c.$1}' : '${c.$2} needs ${c.$1}',
        )
        .join('; ');
    return PlanIssue(
      IssueLevel.blocker,
      'No version of ${planner._name(id)} fits: $why. '
      '${available.isEmpty ? 'None is available.' : 'Available: ${available.join(', ')}.'}',
      id: id,
    );
  }
}

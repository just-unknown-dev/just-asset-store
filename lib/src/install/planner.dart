/// Working out what an install, update or uninstall would change, and
/// whether it can, before anything is touched.
library;

import 'dart:io';

import 'package:just_core_cli/project.dart';

import '../catalog/item_traits.dart';
import '../catalog/reserved_names.dart';
import '../catalog/store_item.dart';
import '../lockfile/store_lock.dart';
import '../project/reference_scan.dart';
import '../project/store_project.dart';
import 'install_plan.dart';
import 'project_state.dart';
import 'store_catalog.dart';
import 'version_resolver.dart';

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

  /// Removes [id], and the dependencies only it needed (the plan's other
  /// changes).
  ///
  /// [references] (from [ReferenceScan], by package: `AssetStore.planUninstall`
  /// scans for every item going at once) are what still uses each: code
  /// that imports [id] or one of those dependencies blocks the plan, and
  /// assets or scenes that use [id] are a warning.
  InstallPlan uninstall(
    String id, {
    Map<String, List<PackageReference>> references = const {},
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
    final own = references[id] ?? const <PackageReference>[];
    final code = own.where((r) => r.kind == ReferenceKind.code);
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
    final assets = own.where((r) => r.kind != ReferenceKind.code);
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
    for (final c in changes) {
      if (c.id == id) continue;
      final code = [
        for (final r in references[c.id] ?? const <PackageReference>[])
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
    final resolver = VersionResolver(catalog, state, targets, nameOf: _name);
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
    // Every package is checked, then staged, one at a time; but the project
    // must have room for them all.
    final unpacked = InstallPlan(changes, const []).unpackedBytes;
    if (unpacked > InstallPlan.largeUnpack) {
      issues.add(
        PlanIssue(
          IssueLevel.warning,
          'This unpacks ${(unpacked / (1 << 20)).ceil()} MiB into the '
          'project: make sure the disk has room for it.',
        ),
      );
    }
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
    final declared = {...v.permissions}
      ..remove(v.nativePlugins.isEmpty ? null : ItemPermission.native);
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

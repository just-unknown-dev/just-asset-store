/// What a project has installed now, as the planner reads it.
library;

import 'dart:io';

import 'package:just_core_cli/project.dart';

import '../catalog/item_manifest.dart';
import '../lockfile/store_block.dart';
import '../lockfile/store_lock.dart';
import '../project/store_project.dart';

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
      } on JsonFormatException {
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

/// Finding the native code a package brings in, from its resolution.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import '../catalog/names.dart';
import '../project/package_info.dart';

/// The packages with native code a package brings into a game: Flutter
/// plugins (a `flutter: plugin:` section in their pubspec) and packages
/// with build hooks (`hook/build.dart`), which run code when the game
/// builds. What the project has anyway — through the packages an item
/// requires, or the store items it depends on — isn't the item's to
/// declare.
abstract final class NativeScan {
  /// What the package [id], resolved in [folder] (or its pub workspace),
  /// brings: every package it depends on, directly or not, but those
  /// [provided] packages bring. Null when [folder] isn't resolved.
  static List<String>? of(
    String folder,
    String id, {
    Set<String> provided = const {},
  }) {
    final config = PackageConfig.read(folder);
    final graph = PackageGraph.read(folder);
    final root = graph?.nodes[id];
    if (config == null || graph == null || root == null) return null;
    Set<String> reach(Iterable<String> roots) {
      final seen = <String>{};
      final queue = [...roots];
      while (queue.isNotEmpty) {
        final name = queue.removeLast();
        if (ReservedNames.sdk.contains(name) || !seen.add(name)) continue;
        queue.addAll(graph.nodes[name]?.dependencies ?? const []);
      }
      return seen;
    }

    final have = reach(provided);
    final mine = reach(root.dependencies.where((d) => !provided.contains(d)));
    return [
      for (final name in mine)
        if (!have.contains(name) && name != id)
          if (config.packages[name] case final p? when bringsNative(p.rootPath))
            name,
    ]..sort();
  }

  /// Whether the package in [root] has native code: a Flutter plugin, or
  /// build hooks.
  static bool bringsNative(String root) {
    if (File('$root/hook/build.dart').existsSync()) return true;
    final pubspec = File('$root/pubspec.yaml');
    if (!pubspec.existsSync()) return false;
    try {
      return isPlugin(loadYaml(pubspec.readAsStringSync()));
    } on Object {
      return false;
    }
  }

  /// Whether a pubspec, as [yaml] reads, is a Flutter plugin's.
  static bool isPlugin(Object? yaml) {
    if (yaml is! Map) return false;
    final flutter = yaml['flutter'];
    return flutter is Map && flutter['plugin'] != null;
  }

  /// The packages build hooks are written with.
  static const Set<String> hookPackages = {'hooks', 'native_assets_cli'};

  /// Libraries for writing build hooks, which have none of their own.
  static const Set<String> hookLibraries = {
    ...hookPackages,
    'code_assets',
    'data_assets',
    'native_toolchain_c',
    'native_toolchain_cmake',
    'record_use',
  };

  /// Whether the package [name], whose pubspec [yaml] reads, has native
  /// code, as its pubspec alone can tell (a package server's answer has no
  /// files): a Flutter plugin, or one that depends on [hookPackages] and
  /// isn't one of the [hookLibraries].
  static bool isNativePubspec(String name, Object? yaml) {
    if (isPlugin(yaml)) return true;
    if (yaml is! Map || hookLibraries.contains(name)) return false;
    final deps = yaml['dependencies'];
    return deps is Map && deps.keys.any(hookPackages.contains);
  }
}

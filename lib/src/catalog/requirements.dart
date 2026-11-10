/// What a version needs of the project it goes into — the engine and
/// editor versions it works with, and the SDKs — and checking that against
/// a project.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'item_traits.dart';
import 'store_item.dart';

/// The names a version's `requires` may use, and the rules for them.
///
/// Every plugin version (an editor extension or a kit) names the range of
/// [engine] versions and the range of [editor] versions it works with, each
/// with an upper limit. The store installs it only into a project whose
/// engine and editor are in both ([ProjectVersions]), from the editor and
/// from `just store` alike.
abstract final class Requirements {
  /// The Dart SDK.
  static const String dart = 'sdk';

  /// The Flutter SDK.
  static const String flutter = 'flutter';

  /// The engine, `just_game_engine`.
  static const String engine = 'just_game_engine';

  /// The editor, `just_game_engine_editor`.
  static const String editor = 'just_game_engine_editor';

  /// Every name `requires` may use: the store checks each one.
  static const List<String> names = [engine, editor, flutter, dart];

  /// The ranges every plugin version names.
  static const List<String> forPlugins = [engine, editor];

  /// [name] for people: "Just Game Engine", "Flutter".
  static String label(String name) => switch (name) {
    dart => 'Dart',
    flutter => 'Flutter',
    engine => 'Just Game Engine',
    editor => 'Just Game Engine Editor',
    _ => name,
  };

  /// Whether a version of an item of [kind] must name [forPlugins]: every
  /// plugin but the editor's own parts ([system]), which are the editor.
  static bool areNeeded(ItemKind kind, {bool system = false}) =>
      kind.isPlugin && !system;

  /// What is wrong with [requires], as a version of an item of [kind]
  /// declares it: a name the store doesn't check, and for a plugin a
  /// missing or open-ended engine or editor range. Empty when nothing is.
  static List<String> problems(
    Map<String, VersionConstraint> requires,
    ItemKind kind, {
    bool system = false,
  }) => [
    for (final name in requires.keys)
      if (!names.contains(name))
        '"requires" names "$name", which the store does not check. It may '
            'name ${names.join(', ')}.',
    if (areNeeded(kind, system: system))
      for (final name in forPlugins)
        switch (requires[name]) {
          null =>
            '"requires" gives no range for $name: every plugin names the '
                '${label(name)} versions it works with, like '
                '"${_example(name)}".',
          final c when c.max == null =>
            '"requires" gives $name "$c", which has no upper limit: name the '
                'versions it was made for, like "${_example(name)}" or '
                '">=${c.min ?? '0.0.0'} <${(c.min ?? Version(0, 0, 0)).nextBreaking}".',
          _ => null,
        },
  ].nonNulls.toList();

  static String _example(String name) => name == editor ? '^0.2.0' : '^2.1.0';

  /// Whether every version [inner] allows, [outer] allows too.
  static bool within(VersionConstraint inner, VersionConstraint outer) {
    final outerMin = outer.min;
    if (outerMin != null) {
      final innerMin = inner.min;
      if (innerMin == null) return false;
      final c = innerMin.compareTo(outerMin);
      if (c < 0 || (c == 0 && inner.includeMin && !outer.includeMin)) {
        return false;
      }
    }
    final outerMax = outer.max;
    if (outerMax != null) {
      final innerMax = inner.max;
      if (innerMax == null) return false;
      final c = innerMax.compareTo(outerMax);
      if (c > 0 || (c == 0 && inner.includeMax && !outer.includeMax)) {
        return false;
      }
    }
    return true;
  }
}

/// The versions a project runs — its engine, editor, Flutter and Dart —
/// and whether a store version can go into it.
final class ProjectVersions {
  /// A project running [versions], by [Requirements] name. [resolved]
  /// says whether its packages were resolved (pub get ran): then a package
  /// missing from [versions] is one it does not have, rather than one the
  /// store can't see.
  const ProjectVersions(this.versions, {this.resolved = true});

  /// The versions, by [Requirements] name.
  final Map<String, Version> versions;

  /// Whether the project's packages were resolved.
  final bool resolved;

  /// The project's version of [name], when known.
  Version? operator [](String name) => versions[name];

  /// Whether the project meets [constraint] on [name]. Flutter and Dart the
  /// store can't always see count as met (pub checks them); the engine and
  /// the editor must be there.
  bool meets(String name, VersionConstraint constraint) {
    if (!Requirements.names.contains(name)) return false;
    final have = versions[name];
    if (have == null) return !Requirements.forPlugins.contains(name);
    return constraint.allows(have);
  }

  /// Whether [version] of [item] can go into the project.
  bool fits(StoreItem item, StoreItemVersion version) =>
      problemWith(item, version) == null;

  /// Why [version] of [item] can't go into the project, in a sentence; null
  /// when it can. A plugin that names no engine or editor range is never
  /// installed, nor is a version needing what this store can't check.
  String? problemWith(StoreItem item, StoreItemVersion version) {
    final what = '${item.name} ${version.version}';
    if (Requirements.areNeeded(item.kind)) {
      for (final name in Requirements.forPlugins) {
        if (!version.requires.containsKey(name)) {
          return "$what doesn't say which ${Requirements.label(name)} "
              'versions it works with, so the store cannot check it.';
        }
      }
    }
    for (final MapEntry(key: name, value: constraint)
        in version.requires.entries) {
      if (meets(name, constraint)) continue;
      final label = Requirements.label(name);
      if (!Requirements.names.contains(name)) {
        return '$what needs $name $constraint, which this version of the '
            'Asset Store cannot check: update it.';
      }
      final have = versions[name];
      if (have != null) {
        return '$what needs $label $constraint; this project has $have.';
      }
      return resolved
          ? '$what needs $label $constraint; this project has none.'
          : "$what needs $label $constraint, and the store can't tell which "
                'this project has: run pub get in it first.';
    }
    return null;
  }
}

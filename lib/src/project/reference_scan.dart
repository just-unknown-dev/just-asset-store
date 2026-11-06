/// Finding what in a project still uses a package, before it is removed.
library;

import 'dart:io';

import 'package:just_core_cli/project.dart' show normalPath;

import '../lockfile/file_hashes.dart';
import 'store_project.dart';

/// How a file uses a package.
enum ReferenceKind {
  /// `import 'package:<name>/…'` (or export, part) in Dart code.
  code,

  /// A `packages/<name>/…` asset path in a JSON or Dart file.
  asset,

  /// A component type the package registers, in a scene or screen.
  component,
}

/// One use of a package somewhere in the project.
final class PackageReference {
  /// [kind] use in [file] (relative to the project) at [line].
  const PackageReference(this.file, this.line, this.kind, this.text);

  /// The file, relative to the project, with `/` between parts.
  final String file;

  /// The line, from 1.
  final int line;

  /// What kind of use.
  final ReferenceKind kind;

  /// The line's text, trimmed.
  final String text;

  @override
  String toString() => '$file:$line: $text';
}

/// A package [ReferenceScan.find] looks for: its name, and the component
/// types its runtime adds.
final class ReferenceTarget {
  /// The package [name], which adds [componentTypes].
  const ReferenceTarget(this.name, {this.componentTypes = const []});

  /// The package's name.
  final String name;

  /// The component types its runtime adds, which scenes and screens save.
  final List<String> componentTypes;
}

/// Scans a project for uses of packages.
abstract final class ReferenceScan {
  /// The folders whose Dart code is read: the app's, and its tests', tools'
  /// and examples' — a package one of them imports, once gone, stops
  /// `flutter test` or a tool compiling as surely as the app.
  static const List<String> codeFolders = [
    'lib',
    'bin',
    'test',
    'integration_test',
    'test_driver',
    'tool',
    'example',
    'benchmark',
  ];

  /// Uses of each of [targets] in [project], by package name, in one pass
  /// over its files:
  /// - Dart imports of `package:<name>/` in the [codeFolders], except the
  ///   store's generated files;
  /// - `packages/<name>/` asset paths in that Dart code, in JSON under
  ///   `assets/`, and in JSON inside the [alsoSearch] folders (other
  ///   installed items);
  /// - scenes and screens (`assets/**.json`) using any of a target's
  ///   component types.
  ///
  /// Files inside the [excluding] folders (the packages' own) are skipped.
  /// It reads the files synchronously: the store runs it on another
  /// isolate.
  static Map<String, List<PackageReference>> find(
    StoreProject project,
    Iterable<ReferenceTarget> targets, {
    Iterable<String> alsoSearch = const [],
    Iterable<String> excluding = const [],
  }) {
    final out = {for (final t in targets) t.name: <PackageReference>[]};
    final finders = [
      for (final t in targets)
        (
          name: t.name,
          import: RegExp(
            '''^\\s*(import|export|part)\\s+['"]package:${t.name}/''',
          ),
          asset: 'packages/${t.name}/',
          types: [
            for (final type in t.componentTypes)
              RegExp('"type"\\s*:\\s*"${RegExp.escape(type)}"'),
          ],
        ),
    ];
    const generated = {StoreProject.modulesFile, StoreProject.extensionsFile};
    final skipped = [for (final f in excluding) normalPath(f)];

    void scan(String folder, bool Function(String path) wanted) {
      final dir = project.dir(folder);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = project.relativeOf(entity.path);
        if (rel == null || !wanted(rel) || FileHashes.isToolPath(rel)) continue;
        if (skipped.any((x) => rel == x || rel.startsWith('$x/'))) continue;
        final List<String> lines;
        try {
          lines = entity.readAsLinesSync();
        } on FileSystemException {
          continue; // not text
        }
        final isDart = rel.endsWith('.dart');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          for (final f in finders) {
            final ReferenceKind kind;
            if (isDart && !generated.contains(rel) && f.import.hasMatch(line)) {
              kind = ReferenceKind.code;
            } else if (line.contains(f.asset)) {
              kind = ReferenceKind.asset;
            } else if (!isDart && f.types.any((p) => p.hasMatch(line))) {
              kind = ReferenceKind.component;
            } else {
              continue;
            }
            out[f.name]!.add(PackageReference(rel, i + 1, kind, line.trim()));
          }
        }
      }
    }

    for (final folder in codeFolders) {
      scan(folder, (p) => p.endsWith('.dart'));
    }
    scan('assets', (p) => p.endsWith('.json'));
    for (final folder in alsoSearch) {
      scan(folder, (p) => p.endsWith('.json'));
    }
    return out;
  }
}

/// Finding what in a project still uses a package, before it is removed.
library;

import 'dart:io';

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

/// Scans a project for uses of a package.
abstract final class ReferenceScan {
  /// Uses of the package [name] in [project]:
  /// - Dart imports of `package:name/` under `lib/`, except the store's
  ///   generated files;
  /// - `packages/name/` asset paths in JSON under `assets/` and in Dart
  ///   under `lib/`, and in JSON inside the [alsoSearch] folders (other
  ///   installed items);
  /// - scenes and screens (`assets/**.json`) using any of [componentTypes].
  ///
  /// Files inside [excluding] (the package's own folder) are skipped.
  static List<PackageReference> find(
    StoreProject project,
    String name, {
    Iterable<String> componentTypes = const [],
    Iterable<String> alsoSearch = const [],
    String? excluding,
  }) {
    final out = <PackageReference>[];
    final importPattern = RegExp(
      '''^\\s*(import|export|part)\\s+['"]package:$name/''',
    );
    final assetNeedle = 'packages/$name/';
    final typePatterns = [
      for (final t in componentTypes)
        RegExp('"type"\\s*:\\s*"${RegExp.escape(t)}"'),
    ];
    const generated = {StoreProject.modulesFile, StoreProject.extensionsFile};

    void scan(String folder, bool Function(String path) wanted) {
      final dir = project.dir(folder);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = project.relativeOf(entity.path);
        if (rel == null || !wanted(rel) || FileHashes.isToolPath(rel)) continue;
        if (excluding != null &&
            (rel == excluding || rel.startsWith('$excluding/'))) {
          continue;
        }
        final List<String> lines;
        try {
          lines = entity.readAsLinesSync();
        } on FileSystemException {
          continue; // not text
        }
        final isDart = rel.endsWith('.dart');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (isDart &&
              !generated.contains(rel) &&
              importPattern.hasMatch(line)) {
            out.add(
              PackageReference(rel, i + 1, ReferenceKind.code, line.trim()),
            );
          } else if (line.contains(assetNeedle)) {
            out.add(
              PackageReference(rel, i + 1, ReferenceKind.asset, line.trim()),
            );
          } else if (!isDart && typePatterns.any((p) => p.hasMatch(line))) {
            out.add(
              PackageReference(
                rel,
                i + 1,
                ReferenceKind.component,
                line.trim(),
              ),
            );
          }
        }
      }
    }

    scan('lib', (p) => p.endsWith('.dart'));
    scan('assets', (p) => p.endsWith('.json'));
    for (final folder in alsoSearch) {
      scan(folder, (p) => p.endsWith('.json'));
    }
    return out;
  }
}

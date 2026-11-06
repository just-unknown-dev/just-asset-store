/// Hashing an installed item's folder on disk, file by file, as the
/// lockfile records it.
library;

import 'dart:io';

import 'package:just_core_cli/project.dart' show normalPath;

import '../lockfile/file_hashes.dart';

/// The hashes of a folder's files, as [FileHashes] makes them: what tells
/// a local edit from what the store installed.
abstract final class FolderHashes {
  /// Every file under [dir], by path relative to it, with its hash
  /// ([FileHashes.of]). Tool folders (`.dart_tool`, `build`, `.git`…) are
  /// skipped ([FileHashes.isToolPath]).
  static Map<String, String> of(Directory dir) {
    final out = <String, String>{};
    if (!dir.existsSync()) return out;
    final base = normalPath(dir.absolute.path);
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = normalPath(entity.absolute.path).substring(base.length + 1);
      if (FileHashes.isToolPath(rel)) continue;
      out[rel] = FileHashes.of(rel, entity.readAsBytesSync());
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }
}

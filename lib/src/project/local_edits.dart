/// Telling the files someone changed in an installed item's folder from
/// those the store put there.
library;

import '../lockfile/store_lock.dart';
import 'folder_hashes.dart';
import 'store_project.dart';

/// What was changed in installed items' folders since the store put them
/// there, read from the hashes the lockfile records ([LockedItem.files]).
abstract final class LocalEdits {
  /// For each of [items] (id → its lockfile entry) that is vendored and
  /// records its files' hashes, the files in its folder that differ from
  /// what the store installed, or that it never installed — sorted; an
  /// item with none is left out. A file that is gone is not counted:
  /// nothing of it is lost.
  ///
  /// Text files are compared as [FolderHashes] hashes them, line endings
  /// aside, so a checkout that turned LF into CRLF is no edit. It hashes
  /// every file: the store runs it on another isolate.
  static Map<String, List<String>> find(
    StoreProject project,
    Map<String, LockedItem> items,
  ) {
    final out = <String, List<String>>{};
    items.forEach((id, item) {
      final path = item.path;
      if (item.origin != ItemOrigin.vendored ||
          path == null ||
          item.files.isEmpty) {
        return;
      }
      final now = FolderHashes.of(project.dir(path));
      final changed = [
        for (final e in now.entries)
          if (item.files[e.key] != e.value) e.key,
      ]..sort();
      if (changed.isNotEmpty) out[id] = changed;
    });
    return out;
  }
}

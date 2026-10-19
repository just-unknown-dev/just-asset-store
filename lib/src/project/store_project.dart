/// Where the store keeps things in a project, and how it writes files.
library;

import 'package:just_core_cli/project.dart';

import '../catalog/json.dart';
import 'lockfile.dart';

export 'package:just_core_cli/project.dart'
    show FileHashes, retryOnLock, writeBytesAtomic, writeTextAtomic;

/// A Flutter project the store installs into: a [JustProject] with the
/// store's lockfile and generated files.
///
/// Paths are relative to [root] and use `/` between parts, as the lockfile
/// and pubspecs write them.
final class StoreProject extends JustProject {
  /// The project whose `pubspec.yaml` is in [root].
  StoreProject(super.root);

  /// The project's pubspec.
  static const String pubspec = JustProject.pubspec;

  /// The overrides file pub reads instead of the pubspec's overrides.
  static const String overrides = JustProject.overrides;

  /// The generated list of editor modules.
  static const String modulesFile = 'lib/editor/store_modules.g.dart';

  /// The generated list of runtime extensions.
  static const String extensionsFile = 'lib/game/store_extensions.g.dart';

  /// The store's scratch folder: staging and the journals of installs, with
  /// the lock beside them — shared with the `just` tool, so one change runs
  /// at a time whoever makes it.
  static const String workDir = JustProject.workDir;

  /// Where the store kept its journals before it built on just_core_cli; a crash
  /// from then is still recovered.
  static const String legacyJournals = '.dart_tool/just_asset_store/txn';

  /// The folder installed items go into.
  static const String packagesDir = JustProject.packagesDir;

  /// Where replaced and removed items go when a change commits: the
  /// editor's trash, so they are restorable from the editor
  /// (just_core_cli's transactions put theirs in `.just_trash` unless told).
  static const String trashRoot = '.editor_trash';

  /// The store's folder in [trashRoot].
  static const String trash = 'store';

  /// Where an item [id] of [category] is installed.
  static String packagePath(String category, String id) =>
      '$packagesDir/$category/$id';

  /// The lockfile, or an empty one when the project has none yet.
  ///
  /// Throws [StoreFormatException] when it exists but is damaged.
  StoreLock readLock() {
    final f = file(StoreLock.fileName);
    if (!f.existsSync()) return StoreLock();
    try {
      return StoreLock.parse(f.readAsStringSync());
    } on StoreFormatException catch (e) {
      throw e.inFile(StoreLock.fileName);
    }
  }

  /// Saves [lock], atomically.
  void writeLock(StoreLock lock) =>
      writeTextAtomic(file(StoreLock.fileName), lock.toText());
}

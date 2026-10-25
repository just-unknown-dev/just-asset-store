/// Where the store keeps things in a project, and how it writes files.
library;

import 'package:just_core_cli/project.dart';

import '../catalog/json.dart';
import '../catalog/store_index.dart';
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

  /// The folder content items go into: `packages/{category}/{name}/`.
  static const String packagesDir = JustProject.packagesDir;

  /// The folder plugins — editor extensions and kits, the code that comes
  /// only through the store — go into: `plugins/{category}/{name}/`.
  static const String pluginsDir = 'plugins';

  /// Every folder the store installs items into, each item in
  /// `{folder}/{category}/{name}/`.
  static const List<String> itemRoots = [packagesDir, pluginsDir];

  /// Where replaced and removed items go when a change commits: the
  /// editor's trash, so they are restorable from the editor
  /// (just_core_cli's transactions put theirs in `.just_trash` unless told).
  static const String trashRoot = '.editor_trash';

  /// The store's folder in [trashRoot].
  static const String trash = 'store';

  /// Where an item [id] of [kind] and [category] is installed: in
  /// [pluginsDir] for an editor extension or a kit, in [packagesDir] for
  /// content ([ItemKind.installFolder]).
  ///
  /// Throws [ArgumentError] for a kind the store never copies into the
  /// project: pub.dev libraries and templates.
  static String itemPath(ItemKind kind, String category, String id) {
    final folder = kind.installFolder;
    if (folder == null) {
      throw ArgumentError.value(
        kind,
        'kind',
        'A ${kind.id} item is not copied into the project',
      );
    }
    return '$folder/$category/$id';
  }

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

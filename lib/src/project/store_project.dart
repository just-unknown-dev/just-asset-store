/// Where the store keeps things in a project, and how it writes files.
library;

import 'dart:io';

import 'package:just_core_cli/project.dart';

import '../catalog/item_traits.dart';
import '../lockfile/store_lock.dart';

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

  /// Where a change in progress keeps what undoes it — its journal,
  /// backups, folders moved aside and staging — with the project lock
  /// beside them: just_core_cli's changes folder (`.just_changes`), shared
  /// with the `just` tool, so one change runs at a time whoever makes it,
  /// and outside `.dart_tool`, so a `flutter clean` after a crash can't
  /// take them.
  static const String changesDir = JustProject.changesDir;

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
  /// Throws [JsonFormatException] when it exists but is damaged.
  StoreLock readLock() {
    final f = file(StoreLock.fileName);
    if (!f.existsSync()) return StoreLock();
    try {
      return StoreLock.parse(f.readAsStringSync());
    } on JsonFormatException catch (e) {
      throw e.inFile(StoreLock.fileName);
    }
  }

  /// Saves [lock], atomically.
  void writeLock(StoreLock lock) =>
      writeTextAtomic(file(StoreLock.fileName), lock.toText());

  /// How the lockfile records the catalog at [indexUri]: one in a folder on
  /// this machine by its path from the project (`store_catalog/index.json`,
  /// `../catalogs/mine/index.json`) — as `just store link` records a
  /// checkout — so a teammate's clone finds it where theirs is, and the
  /// lockfile never holds this machine's drive and folders; any other by
  /// its URL.
  String recordedSource(Uri indexUri) {
    if (indexUri.scheme != 'file' || indexUri.host.isNotEmpty) {
      return '$indexUri';
    }
    return pathTo(normalPath(indexUri.toFilePath()));
  }

  /// Where the catalog the lockfile records as [url] is: an address
  /// (`https:`, `file:`…) as it is, and a folder by its path from the
  /// project's root, wherever the tool runs from.
  String sourceLocation(String url) {
    final isAddress =
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:').hasMatch(url) &&
        !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(url);
    return isAddress
        ? url
        : resolvePath(root, url, windows: Platform.isWindows);
  }

  /// Whether the lockfile's [url] records the catalog at [indexUri]: the
  /// same address, or — for a folder — the same `index.json`.
  bool recordsSource(String url, Uri indexUri) {
    if (url == '$indexUri') return true;
    if (indexUri.scheme != 'file') return false;
    var location = sourceLocation(url);
    if (location.startsWith('file:')) {
      location = Uri.parse(location).toFilePath();
    } else if (location.contains(':') &&
        !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(location)) {
      return false;
    }
    final index = location.endsWith('.json')
        ? location
        : '$location/index.json';
    return samePath(
      normalPath(File(index).absolute.path),
      normalPath(indexUri.toFilePath()),
    );
  }
}

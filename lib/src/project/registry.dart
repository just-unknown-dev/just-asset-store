/// The generated registry files, worked out from the lockfile.
library;

import 'dart:io';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import 'codegen.dart';
import 'lockfile.dart';
import 'package_info.dart';
import 'pubspec_editor.dart';
import 'store_project.dart';

/// The text of the two generated files.
final class RegistryFiles {
  /// [modules] and [extensions], the files' text.
  const RegistryFiles(this.modules, this.extensions);

  /// `lib/editor/store_modules.g.dart`.
  final String modules;

  /// `lib/game/store_extensions.g.dart`.
  final String extensions;

  /// Both, by path in the project.
  Map<String, String> get byPath => {
    StoreProject.modulesFile: modules,
    StoreProject.extensionsFile: extensions,
  };
}

/// Works out and checks the generated registry files.
abstract final class StoreRegistry {
  /// Every locked item's manifest: from [fresh] (just unpacked) when there,
  /// else read from its folder. Items whose manifest is missing or damaged
  /// are left out and named in [problems].
  static Map<String, ItemManifest> manifests(
    StoreProject project,
    StoreLock lock, {
    Map<String, ItemManifest> fresh = const {},
    List<String>? problems,
  }) {
    final out = <String, ItemManifest>{};
    lock.items.forEach((id, item) {
      final ready = fresh[id];
      if (ready != null) {
        out[id] = ready;
        return;
      }
      final path = item.path;
      if (path == null) return;
      final file = project.file('$path/${ItemManifest.fileName}');
      if (!file.existsSync()) {
        problems?.add('$id has no ${ItemManifest.fileName} in $path.');
        return;
      }
      try {
        out[id] = ItemManifest.parse(file.readAsStringSync());
      } on StoreFormatException catch (e) {
        problems?.add('$id: ${e.inFile('$path/${ItemManifest.fileName}')}');
      }
    });
    return out;
  }

  /// The generated files for [lock], whose items' manifests are
  /// [manifests]. Items switched off in the lockfile are left out.
  static RegistryFiles render(
    StoreLock lock,
    Map<String, ItemManifest> manifests,
  ) => RegistryFiles(
    StoreCodegen.modules([
      for (final e in manifests.entries)
        if (lock.items[e.key]?.registerModules ?? false) e.value,
    ]),
    StoreCodegen.extensions([
      for (final e in manifests.entries)
        if (lock.items[e.key]?.registerExtensions ?? false) e.value,
    ]),
  );

  /// The generated files [project] should have with [lock] installed:
  /// each one it has already, and — once the store installed anything —
  /// each one whose import the project resolves (`store_modules.g.dart`
  /// imports just_game_engine_editor, `store_extensions.g.dart`
  /// just_game_engine). A project that never used the store, or is no Just
  /// Game Engine project, gets none it couldn't compile. [pubspec] is the
  /// pubspec's text, when it is about to change.
  static Set<String> wanted(
    StoreProject project,
    StoreLock lock, {
    String? pubspec,
  }) {
    final config = PackageConfig.read(project.root);
    final file = project.file(StoreProject.pubspec);
    final text = pubspec ?? (file.existsSync() ? file.readAsStringSync() : '');
    bool resolves(String package) {
      if (config?.packages.containsKey(package) ?? false) return true;
      try {
        final editor = PubspecEditor.parse(text, marker: storeBlock);
        return editor.unmanaged('dependencies').containsKey(package) ||
            editor.unmanaged('dev_dependencies').containsKey(package);
      } on PubspecEditException {
        return true; // Unreadable: assume so, as before.
      }
    }

    return {
      if (project.file(StoreProject.modulesFile).existsSync() ||
          (lock.items.isNotEmpty && resolves('just_game_engine_editor')))
        StoreProject.modulesFile,
      if (project.file(StoreProject.extensionsFile).existsSync() ||
          (lock.items.isNotEmpty && resolves('just_game_engine')))
        StoreProject.extensionsFile,
    };
  }

  /// What the generated files should hold for [project] now: only those it
  /// should have ([wanted]), by path.
  static Map<String, String> expected(
    StoreProject project, {
    List<String>? problems,
  }) {
    final lock = project.readLock();
    final wanted = StoreRegistry.wanted(project, lock);
    return {
      for (final e in render(
        lock,
        manifests(project, lock, problems: problems),
      ).byPath.entries)
        if (wanted.contains(e.key)) e.key: e.value,
    };
  }

  /// The generated files that are missing or differ from [expected].
  static List<String> outdated(StoreProject project) => [
    for (final e in expected(project).entries)
      if (!_holds(project.file(e.key), e.value)) e.key,
  ];

  /// Writes the generated files that differ; returns which.
  static List<String> write(StoreProject project, {List<String>? problems}) {
    final written = <String>[];
    for (final e in expected(project, problems: problems).entries) {
      final f = project.file(e.key);
      if (_holds(f, e.value)) continue;
      writeTextAtomic(f, e.value);
      written.add(e.key);
    }
    return written;
  }

  /// Whether [file] holds [text], whatever line endings git checked it out
  /// with (`core.autocrlf` turns them into CRLF on Windows).
  static bool _holds(File file, String text) =>
      file.existsSync() &&
      file.readAsStringSync().replaceAll('\r\n', '\n') == text;
}

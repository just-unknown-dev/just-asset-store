/// The generated registry files, worked out from the lockfile.
library;

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import 'codegen.dart';
import 'lockfile.dart';
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

  /// What the generated files should hold for [project] now.
  static RegistryFiles expected(
    StoreProject project, {
    List<String>? problems,
  }) {
    final lock = project.readLock();
    return render(lock, manifests(project, lock, problems: problems));
  }

  /// The generated files that are missing or differ from [expected].
  static List<String> outdated(StoreProject project) {
    final want = expected(project);
    return [
      for (final e in want.byPath.entries)
        if (!project.file(e.key).existsSync() ||
            project.file(e.key).readAsStringSync() != e.value)
          e.key,
    ];
  }

  /// Writes the generated files that differ; returns which.
  static List<String> write(StoreProject project, {List<String>? problems}) {
    final want = expected(project, problems: problems);
    final written = <String>[];
    for (final e in want.byPath.entries) {
      final f = project.file(e.key);
      if (f.existsSync() && f.readAsStringSync() == e.value) continue;
      writeTextAtomic(f, e.value);
      written.add(e.key);
    }
    return written;
  }
}

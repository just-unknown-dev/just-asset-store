/// Store items that are someone's own checkout: linking them, and copying
/// them in as ordinary installed items.
library;

import 'dart:io';
import 'dart:typed_data';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import '../project/lockfile.dart';
import '../project/overrides_target.dart';
import '../project/pub_runner.dart';
import '../project/pubspec_editor.dart';
import '../project/store_project.dart';
import '../sources/store_source.dart';
import '../tools/packer.dart';
import 'installer.dart';
import 'package_check.dart';
import 'planner.dart';

/// Links and vendors store items.
///
/// A **linked** item is a package the project already resolves from a
/// developer's own checkout — the editor's packages in their monorepo, say.
/// The store lists it, registers its modules and extensions, and finds its
/// assets; it never moves, updates or hashes it.
///
/// **Vendoring** copies a linked item into the project as an ordinary
/// installed item, through the same checked, all-or-nothing install: an
/// editor extension or a kit into `plugins/{category}/{name}/`, content into
/// `packages/{category}/{name}/`. A project does this before it is shared,
/// so that a clone has the packages without the checkouts.
abstract final class StoreLinker {
  /// Records the packages in [folders] (each with a `just_store.json`) as
  /// linked items, and regenerates the registry files, all or nothing and
  /// holding the project's lock. Returns their ids.
  ///
  /// Throws [StoreFormatException] for a folder without a valid manifest,
  /// and [InstallFailure] while another change holds the lock.
  static List<String> link(
    StoreProject project,
    List<String> folders, {
    bool direct = true,
  }) {
    final linked = <String, LockedItem>{};
    for (final folder in folders) {
      // An absolute folder as it is; a relative one inside the project when
      // it is there, else from the current folder.
      final dir = File(folder).isAbsolute
          ? Directory(folder)
          : project.dir(folder).existsSync()
          ? project.dir(folder)
          : Directory(folder).absolute;
      final manifest = _manifest(StoreProject(dir.path));
      // Relative when it can be (`../engine/just_x`), so the lockfile does
      // not hold this machine's drive and folders.
      final path = project.pathTo(dir.absolute.path);
      linked[manifest.id] = LockedItem(
        version: '${manifest.version}',
        kind: manifest.kind,
        origin: ItemOrigin.linked,
        category: manifest.category,
        path: path.replaceAll(r'\', '/'),
        direct: direct,
        system: manifest.system,
      );
    }
    StoreInstaller.withLockSync(project, () {
      var lock = project.readLock();
      linked.forEach((id, item) => lock = lock.withItem(id, item));
      StoreInstaller.saveLock(project, lock);
    });
    return linked.keys.toList();
  }

  /// Forgets the linked item [id] (its checkout stays) and regenerates the
  /// registry files, as [link] does. False when [id] is not a linked item.
  static bool unlink(StoreProject project, String id) =>
      StoreInstaller.withLockSync(project, () {
        final lock = project.readLock();
        if (lock.items[id]?.origin != ItemOrigin.linked) return false;
        StoreInstaller.saveLock(project, lock.without(id));
        return true;
      });

  /// Copies the linked items [ids] into the project as ordinary installed
  /// items, in one install — editor extensions and kits into
  /// `plugins/{category}/{name}/`, content into
  /// `packages/{category}/{name}/`: their pubspec entries become the
  /// store's, and pub resolves them from the copies.
  ///
  /// Refused while the live overrides file points one of them at a
  /// checkout — a developer's monorepo: vendor in a clean copy of the
  /// project instead.
  static Future<InstallResult> vendor(
    StoreProject project,
    List<String> ids, {
    required PubRunner pub,
  }) async {
    final lock = project.readLock();
    final target = await OverridesTarget.detect(project);
    final overrides = project.file(target.active);
    final foreign = overrides.existsSync()
        ? PubspecEditor.parse(
            overrides.readAsStringSync(),
            marker: storeBlock,
          ).unmanaged('dependency_overrides')
        : const <String, DependencySpec>{};

    final items = <StoreItem>[];
    final files = <String, Uint8List>{};
    final changes = <PlannedChange>[];
    final problems = <String>[];
    for (final id in ids) {
      final locked = lock.items[id];
      if (locked == null || locked.origin != ItemOrigin.linked) {
        problems.add('$id is not a linked item.');
        continue;
      }
      if (foreign.containsKey(id)) {
        problems.add(
          '${target.active} points $id at a checkout. Vendor in a clean copy '
          'of the project, without that override.',
        );
        continue;
      }
      final PackResult packed;
      try {
        packed = Packer.pack(
          project.dir(locked.path!),
          trust: TrustLevel.official,
        );
      } on PackageCheckException catch (e) {
        problems.add('$e');
        continue;
      } on StoreFormatException catch (e) {
        problems.add('$id: $e');
        continue;
      }
      final m = packed.manifest;
      final archive = 'vendor/${packed.fileName}';
      files[archive] = packed.bytes;
      final item = StoreItem(
        id: m.id,
        name: m.name,
        kind: m.kind,
        category: m.category,
        versions: [
          StoreItemVersion.fromJson(
            JsonFields(packed.versionJson(archive)),
            m.kind,
          ),
        ],
        // A checkout on this machine, linked on purpose: its owner vouches
        // for it, as for a catalog in a folder here.
        trust: TrustLevel.official,
      );
      items.add(item);
      changes.add(
        PlannedChange(
          id: id,
          kind: ChangeKind.update,
          itemKind: m.kind,
          reason: 'Copied from ${locked.path}',
          version: item.versions.single,
          current: locked,
          direct: locked.direct,
          entry: null,
        ),
      );
    }
    if (problems.isNotEmpty) {
      throw InstallFailure(problems.join('\n'), rolledBack: false);
    }
    final source = MemoryStoreSource(
      StoreIndex(
        source: const StoreSourceInfo('local', 'Vendored'),
        categories: const [],
        items: items,
      ),
      files,
    );
    final plan = InstallPlan([
      for (final c in changes)
        PlannedChange(
          id: c.id,
          kind: c.kind,
          itemKind: c.itemKind,
          reason: c.reason,
          version: c.version,
          current: c.current,
          direct: c.direct,
          entry: CatalogEntry(
            'local',
            items.firstWhere((i) => i.id == c.id),
            source: source,
          ),
        ),
    ], const []);
    // A vendored copy came from a checkout, not a catalog: the lockfile
    // records nothing to download it again from.
    return StoreInstaller(
      project: project,
      pub: pub,
    ).apply(plan, replacing: ids.toSet(), unpinned: ids.toSet());
  }

  static ItemManifest _manifest(StoreProject package) {
    final file = package.file(ItemManifest.fileName);
    if (!file.existsSync()) {
      throw StoreFormatException(
        'No ${ItemManifest.fileName} here.',
        file: package.root,
      );
    }
    try {
      return ItemManifest.parse(file.readAsStringSync());
    } on StoreFormatException catch (e) {
      throw e.inFile('${package.root}/${ItemManifest.fileName}');
    }
  }
}

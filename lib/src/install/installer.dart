/// Applying a plan to a project, all or nothing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:just_core_cli/project.dart'
    show ProjectBusyException, ProjectLock, ProjectTransaction;
import 'package:meta/meta.dart';

import '../archive/zip_reader.dart';
import '../catalog/store_index.dart';
import '../project/registry.dart';
import '../project/lockfile.dart';
import '../project/overrides_target.dart';
import '../project/pub_runner.dart';
import '../project/pubspec_editor.dart';
import '../project/store_project.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';
import 'package_check.dart';
import 'planner.dart';

/// A step of an install, as shown to the user.
final class InstallProgress {
  /// [message], [fraction] of the way through (null: unknown).
  const InstallProgress(this.message, {this.fraction});

  /// What is happening now.
  final String message;

  /// How far along, 0 to 1, when known.
  final double? fraction;

  @override
  String toString() =>
      fraction == null ? message : '$message (${(fraction! * 100).round()}%)';
}

/// An install that failed. When [rolledBack], the project is exactly as it
/// was before; when not, the next store command finishes putting it back.
final class InstallFailure implements Exception {
  /// A failure explained by [message], caused by [cause].
  const InstallFailure(this.message, {this.cause, this.rolledBack = true});

  /// What went wrong, for the user.
  final String message;

  /// The underlying error.
  final Object? cause;

  /// Whether everything was put back.
  final bool rolledBack;

  @override
  String toString() => message;
}

/// What an applied plan did.
final class InstallResult {
  /// The result of applying a plan.
  const InstallResult({
    required this.lock,
    required this.changes,
    required this.changedAssets,
    this.setupSnippets = const {},
    this.notes = const [],
    this.pub,
  });

  /// The new lockfile.
  final StoreLock lock;

  /// What was changed.
  final List<PlannedChange> changes;

  /// The `packages/<name>/…` asset keys that appeared, changed or went
  /// away: what the editor should reload.
  final Set<String> changedAssets;

  /// Hand-written setup kits ask for, by item name.
  final Map<String, String> setupSnippets;

  /// Notes from the package checks.
  final List<String> notes;

  /// What `pub get` said.
  final PubResult? pub;

  /// Whether the editor must restart to load new code.
  bool get needsRestart => changes.any((c) => c.needsRestart);
}

/// The points [StoreInstaller.failAfter] can stop at, for tests that prove
/// a failure anywhere leaves the project untouched.
@visibleForTesting
enum InstallStep {
  /// After the backups are made.
  backedUp,

  /// After the new folders are staged.
  staged,

  /// After old folders are moved aside.
  movedAside,

  /// After new folders are moved in.
  movedIn,

  /// After the pubspecs are written.
  pubspecs,

  /// After pub get.
  pubGet,

  /// After the generated files are written.
  generated,

  /// After the lockfile is written.
  locked,
}

/// Applies plans to a project.
///
/// Everything is downloaded and checked before the project is touched.
/// Then, with a journal written ahead of each step: back up every file it
/// will change, stage the new packages beside the project, move old folders
/// aside and new ones in, write the pubspecs, run `pub get`, regenerate the
/// registry files, write the lockfile. A failure at any point puts every
/// file and folder back; a crash is rolled back by [recover] next time.
final class StoreInstaller {
  /// An installer for [project], resolving with [pub] and fetching with
  /// [downloader].
  StoreInstaller({
    required this.project,
    required this.pub,
    Downloader? downloader,
    this.credentials,
    DateTime Function()? clock,
  }) : downloader = downloader ?? Downloader(),
       _clock = clock ?? DateTime.now;

  /// The project.
  final StoreProject project;

  /// Runs `pub get`.
  final PubRunner pub;

  /// Fetches archives.
  final Downloader downloader;

  /// Proves the user may download paid items (reserved).
  final Credentials? credentials;

  final DateTime Function() _clock;

  /// For tests: throw after this step, to prove rollback.
  @visibleForTesting
  InstallStep? failAfter;

  /// For tests: stop dead after this step, as a crash would — no rollback,
  /// so [recover] has something to undo.
  @visibleForTesting
  InstallStep? crashAfter;

  /// Applies [plan]. Throws [InstallFailure] (with everything put back),
  /// or [CancelledException] when [cancel] fires before the project is
  /// touched.
  ///
  /// [replacing] names packages whose hand-written pubspec entries the store
  /// may take over (`just store vendor`); any other clash is refused.
  /// [unpinned] names items copied in from local files: the lockfile records
  /// no archive or source to download them again from. [files] (path in
  /// the project → bytes) are written in the same change, before the
  /// pubspecs are edited and pub runs: a template's files, say. With
  /// [files], a plan with nothing else to do still applies.
  Future<InstallResult> apply(
    InstallPlan plan, {
    void Function(InstallProgress)? onProgress,
    CancelToken? cancel,
    Set<String> replacing = const {},
    Set<String> unpinned = const {},
    Map<String, Uint8List> files = const {},
  }) async {
    final blocked = plan.blockers.isNotEmpty;
    if (blocked || (plan.changes.isEmpty && files.isEmpty)) {
      throw InstallFailure(
        blocked
            ? plan.blockers.map((b) => b.message).join('\n')
            : 'There is nothing to do.',
        rolledBack: false,
      );
    }
    void report(String message, [double? fraction]) =>
        onProgress?.call(InstallProgress(message, fraction: fraction));

    // 1. Fetch and check everything, touching nothing (and holding no lock:
    // this is the slow part).
    final packages = <String, CheckedPackage>{};
    final archives = <String, LockedArchive>{};
    final fetches = plan.changes
        .where(
          (c) =>
              (c.kind == ChangeKind.install || c.kind == ChangeKind.update) &&
              c.itemKind.isVendored,
        )
        .toList();
    for (var i = 0; i < fetches.length; i++) {
      cancel?.check();
      final c = fetches[i];
      final entry = c.entry!;
      final source = entry.source;
      if (source == null) {
        throw InstallFailure(
          'Nowhere to download ${c.name} from.',
          rolledBack: false,
        );
      }
      report('Downloading ${c.name} ${c.version!.version}', i / fetches.length);
      final Uint8List bytes;
      try {
        bytes = await downloader.archive(
          source,
          entry.item,
          c.version!,
          cancel: cancel,
          credentials: credentials,
          onProgress: (got, total) => report(
            'Downloading ${c.name} ${c.version!.version}',
            (i + (total == null || total == 0 ? 0 : got / total)) /
                fetches.length,
          ),
        );
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        throw InstallFailure('$e', cause: e, rolledBack: false);
      }
      report('Checking ${c.name}');
      try {
        packages[c.id] = PackageCheck.check(
          ZipArchive.read(bytes),
          entry.item,
          c.version!,
        );
      } on Object catch (e) {
        throw InstallFailure(
          e is PackageCheckException ? '$e' : '${c.name}: $e',
          cause: e,
          rolledBack: false,
        );
      }
      archives[c.id] = LockedArchive(
        '${source.resolve(c.version!.archive!.url)}',
        c.version!.archive!.sha256,
      );
    }
    cancel?.check();

    // From here on, one change at a time. A change a crash left half done is
    // rolled back first, by whoever holds the lock.
    return withLock(project, () async {
      // 2. Work out every new file in memory, so a refusal touches nothing.
      final before = project.readLock();
      final now = _clock().toUtc();
      final (withSources, sourceIds) = _withSources(before, plan, unpinned);
      var lock = withSources;
      for (final c in plan.changes) {
        if (c.kind == ChangeKind.remove) {
          lock = lock.without(c.id);
          continue;
        }
        if (c.kind == ChangeKind.adopt) {
          final current = lock.items[c.id] ?? c.current!;
          lock = lock.withItem(c.id, current.copyWith(direct: true));
          continue;
        }
        final v = c.version!;
        final from = c.entry!.source;
        final source = unpinned.contains(c.id)
            ? null
            : sourceIds['${from?.indexUri}'] ?? c.entry!.sourceId;
        if (!c.itemKind.isVendored) {
          lock = lock.withItem(
            c.id,
            LockedItem(
              version: '${v.pubConstraint ?? '^${v.version}'}',
              kind: c.itemKind,
              origin: ItemOrigin.hosted,
              direct: c.direct,
              source: source,
              installedAt: now,
            ),
          );
          continue;
        }
        final package = packages[c.id]!;
        lock = lock.withItem(
          c.id,
          LockedItem(
            version: '${v.version}',
            kind: c.itemKind,
            origin: ItemOrigin.vendored,
            category: c.entry!.item.category,
            path: c.path,
            direct: c.direct,
            source: source,
            archive: unpinned.contains(c.id) ? null : archives[c.id],
            installedAt: now,
            registerModules: c.current?.registerModules ?? true,
            registerExtensions: c.current?.registerExtensions ?? true,
            files: {
              for (final f in package.files.entries)
                f.key: FileHashes.of(f.key, f.value),
            },
            entitlement: c.current?.entitlement,
            // Only the store's own team may mark an item part of the
            // editor: a community one claiming it could never be removed.
            system:
                c.entry!.item.isOfficial &&
                (c.current?.system ?? package.manifest.system),
            official: c.entry!.item.isOfficial,
          ),
        );
      }
      final target = await OverridesTarget.detect(project);
      _checkUndeclared(plan, packages, lock, _ownOverrides(target, files));
      final texts = _pubspecTexts(lock, target, replacing, files);

      // 3. Change the project, journal first.
      final txn = ProjectTransaction.begin(
        project,
        now: now,
        trash: StoreProject.trash,
        trashRoot: StoreProject.trashRoot,
      );
      try {
        report('Backing up');
        txn.backUp([
          StoreProject.pubspec,
          StoreProject.overrides,
          'pubspec.lock',
          '.dart_tool/package_config.json',
          '.dart_tool/package_graph.json',
          StoreLock.fileName,
          StoreProject.modulesFile,
          StoreProject.extensionsFile,
        ]);
        _maybeFail(InstallStep.backedUp);

        report('Unpacking');
        for (final e in packages.entries) {
          txn.stage(e.key, e.value.files, executable: e.value.executable);
        }
        _maybeFail(InstallStep.staged);

        for (final c in plan.changes) {
          final old = c.current?.path;
          if ((c.kind == ChangeKind.update || c.kind == ChangeKind.remove) &&
              c.current?.origin == ItemOrigin.vendored &&
              old != null &&
              project.dir(old).existsSync()) {
            txn.moveAside(c.id, old);
          }
        }
        _maybeFail(InstallStep.movedAside);
        for (final c in plan.changes) {
          if (packages.containsKey(c.id)) txn.moveIn(c.id, c.path!);
        }
        _maybeFail(InstallStep.movedIn);

        files.forEach(txn.writeBytes);
        for (final e in texts.entries) {
          txn.write(e.key, e.value);
        }
        _maybeFail(InstallStep.pubspecs);

        report('Resolving packages (pub get)');
        final result = await pub.get(project.root);
        if (!result.ok) {
          throw InstallFailure(
            'pub get failed, so nothing was changed:\n${result.summary}',
            cause: result,
          );
        }
        _maybeFail(InstallStep.pubGet);

        report('Registering');
        final wanted = StoreRegistry.wanted(
          project,
          lock,
          pubspec:
              texts[StoreProject.pubspec] ?? _text(files, StoreProject.pubspec),
        );
        final registry = StoreRegistry.render(
          lock,
          StoreRegistry.manifests(
            project,
            lock,
            fresh: {for (final e in packages.entries) e.key: e.value.manifest},
          ),
        );
        registry.byPath.forEach((path, text) {
          if (wanted.contains(path)) txn.writeIfChanged(path, text);
        });
        _maybeFail(InstallStep.generated);

        txn.write(StoreLock.fileName, lock.toText());
        _maybeFail(InstallStep.locked);

        txn.commit();
        report('Done', 1);
        return InstallResult(
          lock: lock,
          changes: plan.changes,
          changedAssets: _changedAssets(plan, before, packages),
          setupSnippets: {
            for (final c in plan.changes)
              c.name: ?packages[c.id]?.manifest.setupSnippet,
          },
          notes: [for (final p in packages.values) ...p.notes],
          pub: result,
        );
      } on Object catch (e) {
        if (e is SimulatedCrash) rethrow;
        try {
          txn.rollBack();
        } on Object catch (r) {
          throw InstallFailure(
            'The install failed (${_why(e)}), and putting the project back '
            'failed too ($r). The next store command finishes putting it '
            'back.',
            cause: e,
            rolledBack: false,
          );
        }
        if (e is InstallFailure) rethrow;
        throw InstallFailure(
          'The install failed and was undone: ${_why(e)}',
          cause: e,
        );
      }
    });
  }

  /// Runs [change] holding [project]'s lock, once any change a crash left
  /// half done is rolled back: what every store command that writes the
  /// lockfile, the registries or the installed folders goes through, so
  /// one change runs at a time and a recovery never undoes a later one.
  ///
  /// Throws [InstallFailure] when another change holds the lock.
  static Future<T> withLock<T>(
    StoreProject project,
    Future<T> Function() change,
  ) async {
    final lock = _lock(project);
    try {
      _recover(project);
      return await change();
    } finally {
      lock.release();
    }
  }

  /// [withLock] for a [change] that does its work at once.
  static T withLockSync<T>(StoreProject project, T Function() change) {
    final lock = _lock(project);
    try {
      _recover(project);
      return change();
    } finally {
      lock.release();
    }
  }

  /// Writes [lock] and the registry files it makes, all or nothing: the
  /// lockfile-only changes (`link`, `unlink`) go through this, under
  /// [withLock].
  static void saveLock(StoreProject project, StoreLock lock) {
    final txn = ProjectTransaction.begin(
      project,
      trash: StoreProject.trash,
      trashRoot: StoreProject.trashRoot,
    );
    try {
      txn.write(StoreLock.fileName, lock.toText());
      final wanted = StoreRegistry.wanted(project, lock);
      StoreRegistry.render(
        lock,
        StoreRegistry.manifests(project, lock),
      ).byPath.forEach((path, text) {
        if (wanted.contains(path)) txn.writeIfChanged(path, text);
      });
      txn.commit();
    } on Object {
      txn.rollBack();
      rethrow;
    }
  }

  /// Rolls back an install that a crash left half done. Returns whether
  /// there was one.
  ///
  /// Does nothing (returns false) while another install holds the
  /// project's lock: that one is still running.
  static Future<bool> recover(StoreProject project) async {
    final lock = ProjectLock.tryAcquire(project);
    if (lock == null) return false;
    try {
      return _recover(project);
    } finally {
      lock.release();
    }
  }

  static bool _recover(StoreProject project) => ProjectTransaction.recover(
    project,
    trash: StoreProject.trash,
    trashRoot: StoreProject.trashRoot,
  );

  static ProjectLock _lock(StoreProject project) {
    try {
      return ProjectLock.acquire(project);
    } on ProjectBusyException catch (e) {
      // Nothing was changed: the project is as it was.
      throw InstallFailure(
        'Another install is running in this project. Wait for it to '
        'finish. (${e.message})',
        cause: e,
      );
    }
  }

  static String _why(Object e) => e is StateError ? e.message : '$e';

  /// [lock] recording where [plan]'s new items came from, so later runs
  /// read the same catalogs, with the id each source is recorded under (by
  /// its address). A project that recorded none read the official catalog:
  /// recording another keeps it too, first. A recorded source is never
  /// replaced by another address that claims its id: that one is recorded
  /// under an id of its own.
  (StoreLock, Map<String, String>) _withSources(
    StoreLock lock,
    InstallPlan plan,
    Set<String> unpinned,
  ) {
    final ids = <String, String>{};
    for (final c in plan.changes) {
      final source = c.entry?.source;
      if ((c.kind != ChangeKind.install && c.kind != ChangeKind.update) ||
          source == null ||
          unpinned.contains(c.id)) {
        continue;
      }
      final url = '${source.indexUri}';
      if (lock.sources.isEmpty && url != SourceConfig.official.url) {
        lock = lock.withSource(
          LockedSource(SourceConfig.officialId, SourceConfig.official.url),
        );
      }
      final known = lock.sources.where((s) => s.url == url).firstOrNull;
      if (known != null) {
        ids[url] = known.id;
        continue;
      }
      final claimed = c.entry!.sourceId;
      var id = claimed;
      for (var n = 2; lock.sources.any((s) => s.id == id); n++) {
        id = '$claimed-$n';
      }
      lock = lock.withSource(LockedSource(id, url));
      ids[url] = id;
    }
    return (lock, ids);
  }

  /// What the project overrides by hand (in its live overrides file, or
  /// [files] about to be written): developer checkouts, which pub takes
  /// instead of anything on pub.dev.
  Set<String> _ownOverrides(
    OverridesTarget target,
    Map<String, Uint8List> files,
  ) {
    final text =
        _text(files, target.active) ??
        (project.file(target.active).existsSync()
            ? project.file(target.active).readAsStringSync()
            : null);
    if (text == null) return const {};
    try {
      return PubspecEditor.parse(
        text,
        marker: storeBlock,
      ).unmanaged('dependency_overrides').keys.toSet();
    } on PubspecEditException {
      return const {};
    }
  }

  /// Refuses a package whose pubspec depends on a store item it doesn't
  /// declare, when nothing installs or overrides that item: pub would look
  /// for a package of that name on pub.dev, which could be anyone's.
  void _checkUndeclared(
    InstallPlan plan,
    Map<String, CheckedPackage> packages,
    StoreLock lock,
    Set<String> overridden,
  ) {
    final catalog = plan.catalog;
    if (catalog == null) return;
    for (final c in plan.changes) {
      final package = packages[c.id];
      if (package == null) continue;
      for (final dep in package.dependencies) {
        if (lock.items.containsKey(dep) || overridden.contains(dep)) continue;
        final item = catalog.entry(dep)?.item;
        if (item == null || !item.kind.isVendored) continue;
        throw InstallFailure(
          '${c.name} depends on ${item.name} ($dep), a store item, without '
          'saying so in its just_store.json: pub would look for another '
          'package named $dep on pub.dev. Its publisher has to add it to the '
          "package's dependencies.",
          rolledBack: false,
        );
      }
    }
  }

  /// [files]' [path] as text, when it is one of them.
  static String? _text(Map<String, Uint8List> files, String path) {
    final bytes = files[path];
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  void _maybeFail(InstallStep step) {
    if (crashAfter == step) throw SimulatedCrash(step);
    if (failAfter == step) {
      throw StateError('Test failure after ${step.name}.');
    }
  }

  /// The new text of every pubspec file whose blocks change. [files] about
  /// to be written count as the project's.
  Map<String, String> _pubspecTexts(
    StoreLock lock,
    OverridesTarget target,
    Set<String> replacing,
    Map<String, Uint8List> files,
  ) {
    final deps = <String, DependencySpec>{};
    final devDeps = <String, DependencySpec>{};
    final overrides = <String, DependencySpec>{};
    lock.items.forEach((id, item) {
      if (item.origin == ItemOrigin.linked) return;
      if (item.origin == ItemOrigin.hosted) {
        if (item.direct) deps[id] = HostedDependency(item.version);
        return;
      }
      final spec = PathDependency(item.path!);
      overrides[id] = spec;
      if (!item.direct) return;
      (item.isDevDependency ? devDeps : deps)[id] = spec;
    });
    final out = <String, String>{};
    String? read(String file) {
      final written = _text(files, file);
      if (written != null) return written;
      final f = project.file(file);
      return f.existsSync() ? f.readAsStringSync() : null;
    }

    final pubspecText = read(StoreProject.pubspec);
    if (pubspecText == null) {
      throw const InstallFailure(
        'This folder has no pubspec.yaml.',
        rolledBack: false,
      );
    }
    try {
      final pubspec = PubspecEditor.parse(pubspecText, marker: storeBlock);
      for (final name in replacing) {
        for (final section in const [
          'dependencies',
          'dev_dependencies',
          'dependency_overrides',
        ]) {
          pubspec.removeUnmanaged(section, name);
        }
      }
      pubspec
        ..setManaged('dependencies', deps)
        ..setManaged('dev_dependencies', devDeps);
      if (target.files.contains(StoreProject.pubspec)) {
        pubspec.setManaged('dependency_overrides', overrides);
      }
      if (pubspec.text != pubspecText) out[StoreProject.pubspec] = pubspec.text;
      if (target.active == StoreProject.overrides) {
        final text = read(StoreProject.overrides) ?? '';
        final o = PubspecEditor.parse(text, marker: storeBlock)
          ..setManaged('dependency_overrides', overrides);
        if (o.text != text) out[StoreProject.overrides] = o.text;
      }
    } on PubspecEditException catch (e) {
      throw InstallFailure(
        'The store cannot edit the pubspec: ${e.message}',
        cause: e,
        rolledBack: false,
      );
    }
    return out;
  }

  Set<String> _changedAssets(
    InstallPlan plan,
    StoreLock before,
    Map<String, CheckedPackage> packages,
  ) {
    final out = <String>{};
    for (final c in plan.changes) {
      if (c.itemKind != ItemKind.content || c.kind == ChangeKind.adopt) {
        continue;
      }
      for (final f in [
        ...?packages[c.id]?.files.keys,
        ...?before.items[c.id]?.files.keys,
      ]) {
        if (f.contains('/')) out.add('packages/${c.id}/$f');
      }
    }
    return out;
  }
}

/// Thrown by [StoreInstaller.crashAfter] in tests: stands for the process
/// dying mid-install.
@visibleForTesting
final class SimulatedCrash implements Exception {
  /// A crash after [step].
  const SimulatedCrash(this.step);

  /// Where it happened.
  final InstallStep step;

  @override
  String toString() => 'Simulated crash after ${step.name}.';
}

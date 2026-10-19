/// Applying a plan to a project, all or nothing.
library;

import 'dart:typed_data';

import 'package:just_core_cli/project.dart'
    show ProjectBusyException, ProjectLock, ProjectTransaction;

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
/// was before.
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
  bool get needsRestart => changes.any((c) => c.itemKind.needsRestart);
}

/// The points [StoreInstaller.failAfter] can stop at, for tests that prove
/// a failure anywhere leaves the project untouched.
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
  InstallStep? failAfter;

  /// For tests: stop dead after this step, as a crash would — no rollback,
  /// so [recover] has something to undo.
  InstallStep? crashAfter;

  /// Applies [plan]. Throws [InstallFailure] (with everything put back),
  /// or [CancelledException] when [cancel] fires before the project is
  /// touched.
  ///
  /// [replacing] names packages whose hand-written pubspec entries the store
  /// may take over (`just store vendor`); any other clash is refused.
  Future<InstallResult> apply(
    InstallPlan plan, {
    void Function(InstallProgress)? onProgress,
    CancelToken? cancel,
    Set<String> replacing = const {},
  }) async {
    if (!plan.canApply) {
      throw InstallFailure(
        plan.changes.isEmpty
            ? 'There is nothing to do.'
            : plan.blockers.map((b) => b.message).join('\n'),
        rolledBack: false,
      );
    }
    void report(String message, [double? fraction]) =>
        onProgress?.call(InstallProgress(message, fraction: fraction));

    {
      // 1. Fetch and check everything, touching nothing (and holding no
      // lock: this is the slow part).
      final packages = <String, CheckedPackage>{};
      final archives = <String, LockedArchive>{};
      final fetches = plan.changes
          .where((c) => c.kind != ChangeKind.remove && c.itemKind.isVendored)
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
        report(
          'Downloading ${c.name} ${c.version!.version}',
          i / fetches.length,
        );
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

      // From here on, one install at a time. A transaction a crash left
      // half done is rolled back first, by whoever holds the lock.
      final lockFile = _lock(project);
      try {
        _recover(project);

        // 2. Work out every new file in memory, so a refusal touches nothing.
        final before = project.readLock();
        final now = _clock().toUtc();
        var lock = before;
        for (final c in plan.changes) {
          if (c.kind == ChangeKind.remove) {
            lock = lock.without(c.id);
            continue;
          }
          final v = c.version!;
          if (!c.itemKind.isVendored) {
            lock = lock.withItem(
              c.id,
              LockedItem(
                version: '${v.pubConstraint ?? '^${v.version}'}',
                kind: c.itemKind,
                origin: ItemOrigin.hosted,
                direct: c.direct,
                source: c.entry!.sourceId,
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
              source: c.entry!.sourceId,
              archive: archives[c.id],
              installedAt: now,
              registerModules: c.current?.registerModules ?? true,
              registerExtensions: c.current?.registerExtensions ?? true,
              files: {
                for (final f in package.files.entries)
                  f.key: FileHashes.of(f.key, f.value),
              },
              entitlement: c.current?.entitlement,
              system: c.current?.system ?? package.manifest.system,
            ),
          );
        }
        // Remember where things came from, so `just store restore` and the
        // tool know the project's sources.
        for (final c in plan.changes) {
          final source = c.entry?.source;
          if (c.kind != ChangeKind.remove && source != null) {
            lock = lock.withSource(
              LockedSource(c.entry!.sourceId, '${source.indexUri}'),
            );
          }
        }
        final target = await OverridesTarget.detect(project);
        final texts = _pubspecTexts(lock, target, replacing);

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
            if (c.kind != ChangeKind.install &&
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
          final registry = StoreRegistry.render(
            lock,
            StoreRegistry.manifests(
              project,
              lock,
              fresh: {
                for (final e in packages.entries) e.key: e.value.manifest,
              },
            ),
          );
          registry.byPath.forEach(txn.writeIfChanged);
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
          txn.rollBack();
          if (e is InstallFailure) rethrow;
          throw InstallFailure(
            'The install failed and was undone: $e',
            cause: e,
          );
        }
      } finally {
        lockFile.release();
      }
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

  // Journals in the folder the store used before it built on just_core_cli are
  // recovered too.
  static bool _recover(StoreProject project) => ProjectTransaction.recover(
    project,
    alsoIn: const [StoreProject.legacyJournals],
    trash: StoreProject.trash,
    trashRoot: StoreProject.trashRoot,
  );

  static ProjectLock _lock(StoreProject project) {
    try {
      return ProjectLock.acquire(project);
    } on ProjectBusyException {
      throw const InstallFailure(
        'Another install is running in this project. Wait for it to finish.',
        rolledBack: false,
      );
    }
  }

  void _maybeFail(InstallStep step) {
    if (crashAfter == step) throw SimulatedCrash(step);
    if (failAfter == step) {
      throw StateError('Test failure after ${step.name}.');
    }
  }

  /// The new text of every pubspec file whose blocks change.
  Map<String, String> _pubspecTexts(
    StoreLock lock,
    OverridesTarget target,
    Set<String> replacing,
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
      if (c.itemKind != ItemKind.content) continue;
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
final class SimulatedCrash implements Exception {
  /// A crash after [step].
  const SimulatedCrash(this.step);

  /// Where it happened.
  final InstallStep step;

  @override
  String toString() => 'Simulated crash after ${step.name}.';
}

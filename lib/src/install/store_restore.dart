/// Rebuilding installed packages from the lockfile, as `pub get` does for
/// hosted ones — for a fresh clone of a project that keeps the installed
/// items (`plugins/{category}/`, `packages/{category}/`) out of git, or
/// after a folder was deleted.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/project.dart';

import '../catalog/item_traits.dart';
import '../catalog/store_item.dart';
import '../lockfile/store_lock.dart';
import '../project/store_project.dart';
import '../project/store_registry.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';
import 'checked_archive.dart';
import 'store_installer.dart';

/// What [StoreRestore.run] did.
final class RestoreResult {
  /// [restored] item ids; [problems] for those that could not be.
  const RestoreResult(this.restored, this.problems, {this.pub});

  /// The items put back.
  final List<String> restored;

  /// Why others could not be, one per item.
  final List<String> problems;

  /// What `pub get` said afterwards, when anything was restored.
  final PubResult? pub;
}

/// Puts back the locked items whose folders are missing.
abstract final class StoreRestore {
  /// Downloads each vendored item in [project]'s lockfile whose folder is
  /// gone, from the archive it was installed from, checked against the
  /// recorded SHA-256 (on another isolate, as installs are); then, holding
  /// the project's lock, puts the folders back in one change, all or
  /// nothing. Once that change has committed it runs `pub get` and
  /// refreshes the registry files, still holding the lock: a `pub get` that
  /// fails leaves the folders back, and says so in [RestoreResult.problems].
  static Future<RestoreResult> run(
    StoreProject project, {
    required PubRunner pub,
    Downloader? downloader,
    HttpClient Function()? client,
    void Function(InstallProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final lock = project.readLock();
    final ready = <String, CheckedArchive>{};
    final problems = <String>[];
    final missing = [
      for (final e in lock.items.entries)
        if (e.value.origin == ItemOrigin.vendored &&
            e.value.path != null &&
            !project.dir(e.value.path!).existsSync())
          e,
    ];
    for (var i = 0; i < missing.length; i++) {
      cancel?.check();
      final id = missing[i].key;
      final item = missing[i].value;
      final archive = item.archive;
      onProgress?.call(
        InstallProgress('Restoring $id', fraction: i / missing.length),
      );
      if (archive == null) {
        problems.add('$id was copied in from a local folder; copy it again.');
        continue;
      }
      try {
        final bytes = await _fetch(
          project,
          archive.url,
          archive.sha256,
          downloader?.cache,
          client,
          cancel,
        );
        final version = Version.parse(item.version);
        final storeItem = StoreItem(
          id: id,
          name: id,
          kind: item.kind,
          category: item.category ?? '',
          versions: [StoreItemVersion(version: version)],
          trust: item.official ? TrustLevel.official : TrustLevel.community,
        );
        // No catalog here: the lockfile's pin is what it is checked against.
        ready[id] = await CheckedArchive.check(
          bytes,
          storeItem,
          storeItem.versions.single,
          sha256: archive.sha256,
          cache: downloader?.cache,
          matchDependencies: false,
        );
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        problems.add('$id: $e');
      }
    }
    if (ready.isEmpty) return RestoreResult(const [], problems);
    cancel?.check();
    return StoreInstaller.withLock(project, () async {
      // The lockfile again, now that no change can be running: what changed
      // since is left as it is.
      final now = project.readLock();
      final restored = <String>[];
      final txn = ProjectTransaction.begin(
        project,
        trash: StoreProject.trash,
        trashRoot: StoreProject.trashRoot,
      );
      try {
        for (final e in ready.entries) {
          final item = now.items[e.key];
          final was = lock.items[e.key];
          if (item == null ||
              item.path != was?.path ||
              item.archive?.sha256 != was?.archive?.sha256 ||
              project.dir(item.path!).existsSync()) {
            continue;
          }
          txn.stage(
            e.key,
            await e.value.files(downloader?.cache),
            executable: e.value.executable,
          );
          txn.moveIn(e.key, item.path!);
          restored.add(e.key);
        }
        txn.commit();
      } on Object {
        txn.rollBack();
        rethrow;
      }
      PubResult? result;
      if (restored.isNotEmpty) {
        onProgress?.call(const InstallProgress('Resolving packages (pub get)'));
        result = await pub.get(project.root);
        if (!result.ok) problems.add('pub get failed:\n${result.summary}');
        StoreRegistry.write(project);
      }
      return RestoreResult(restored, problems, pub: result);
    });
  }

  /// The archive the lockfile pins at [url] (a URL, or a path from the
  /// project) with [sha256]: from [cache], a folder on this machine, or the
  /// web. Reading and hashing run on another isolate.
  static Future<Uint8List> _fetch(
    StoreProject project,
    String url,
    String sha256,
    DownloadCache? cache,
    HttpClient Function()? client,
    CancelToken? cancel,
  ) async {
    if (cache != null) {
      final cached = await Isolate.run(() => cache.archive(sha256));
      if (cached != null) return cached;
    }
    // A URL, or (for a folder catalog's archive) a path from the project.
    final location = project.sourceLocation(url);
    final uri = location == url && !File(url).isAbsolute
        ? Uri.parse(url)
        : Uri.file(location);
    final Uint8List bytes;
    if (uri.scheme == 'file') {
      // A folder catalog on this machine; never another machine's share,
      // which Windows would sign in to with the user's account.
      if (uri.host.isNotEmpty) {
        throw DownloadException(
          'The lockfile names an archive on another machine ($uri), so it '
          'was not fetched.',
        );
      }
      final path = File.fromUri(uri).path;
      bytes = await Isolate.run(() {
        final file = File(path);
        if (file.lengthSync() > StoreArchive.maxSize) {
          throw const DownloadException(
            'The archive is larger than the store downloads.',
          );
        }
        return file.readAsBytesSync();
      });
    } else {
      bytes = await HttpStoreSource(
        uri,
        client: client,
      ).readBytes(uri, cancel: cancel, maxBytes: StoreArchive.maxSize);
    }
    await Isolate.run(() {
      if (Sha256.hexOf(bytes) != sha256) {
        throw const DownloadException(
          'The archive no longer matches the fingerprint recorded when it '
          'was installed, so it was refused.',
        );
      }
      cache?.putArchive(sha256, bytes);
    });
    return bytes;
  }
}

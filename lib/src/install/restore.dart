/// Rebuilding installed packages from the lockfile, as `pub get` does for
/// hosted ones — for a fresh clone of a project that keeps
/// `packages/{category}/` out of git, or after a folder was deleted.
library;

import 'dart:io';
import 'dart:typed_data';

import '../archive/zip_reader.dart';
import '../catalog/semver.dart';
import '../catalog/store_index.dart';
import '../crypto/sha256.dart';
import '../project/lockfile.dart';
import '../project/pub_runner.dart';
import '../project/registry.dart';
import '../project/store_project.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';
import 'installer.dart';
import 'package_check.dart';

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
  /// recorded SHA-256; then runs `pub get` and refreshes the registry
  /// files.
  static Future<RestoreResult> run(
    StoreProject project, {
    required PubRunner pub,
    Downloader? downloader,
    HttpClient Function()? client,
    void Function(InstallProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final lock = project.readLock();
    final restored = <String>[];
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
          Uri.parse(archive.url),
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
        );
        final checked = PackageCheck.check(
          ZipArchive.read(bytes),
          storeItem,
          storeItem.versions.single,
        );
        final staging = project.dir('${StoreProject.workDir}/restore/$id');
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        checked.files.forEach((path, data) {
          File('${staging.path}/$path')
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(data);
        });
        final target = project.dir(item.path!);
        target.parent.createSync(recursive: true);
        retryOnLock(() => staging.renameSync(target.path));
        restored.add(id);
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        problems.add('$id: $e');
      }
    }
    PubResult? result;
    if (restored.isNotEmpty) {
      onProgress?.call(const InstallProgress('Resolving packages (pub get)'));
      result = await pub.get(project.root);
      if (!result.ok) problems.add('pub get failed:\n${result.summary}');
      StoreRegistry.write(project);
    }
    final leftover = project.dir('${StoreProject.workDir}/restore');
    if (leftover.existsSync()) leftover.deleteSync(recursive: true);
    return RestoreResult(restored, problems, pub: result);
  }

  static Future<Uint8List> _fetch(
    Uri uri,
    String sha256,
    DownloadCache? cache,
    HttpClient Function()? client,
    CancelToken? cancel,
  ) async {
    final cached = cache?.archive(sha256);
    if (cached != null) return cached;
    final Uint8List bytes;
    if (uri.scheme == 'file') {
      bytes = File.fromUri(uri).readAsBytesSync();
    } else {
      bytes = await HttpStoreSource(
        uri,
        client: client,
      ).readBytes(uri, cancel: cancel, maxBytes: 1024 * 1024 * 1024);
    }
    if (Sha256.hexOf(bytes) != sha256) {
      throw const DownloadException(
        'The archive no longer matches the fingerprint recorded when it was '
        'installed, so it was refused.',
      );
    }
    cache?.putArchive(sha256, bytes);
    return bytes;
  }
}

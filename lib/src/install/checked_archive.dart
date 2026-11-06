/// A package archive checked on another isolate, kept as what an install
/// needs of it — never its unpacked files.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';
import 'package:meta/meta.dart';

import '../catalog/item_manifest.dart';
import '../catalog/store_item.dart';
import '../checks/package_check.dart';
import '../lockfile/file_hashes.dart';

/// A package archive that passed [PackageCheck.check], as an install keeps
/// it until it is staged: its manifest, notes, dependencies and executable
/// files, and every file's hash ([FileHashes.of]) — but not the unpacked
/// files, which [files] unpacks again when they are staged.
///
/// Hashing and inflating are pure Dart and take seconds for a large
/// archive (SHA-256 and inflate run at roughly 100 MiB a second each in
/// the editor), so both run on another isolate, never the caller's: the
/// editor's window keeps drawing. And a plan that installs several large
/// items holds one package's files at a time, not all of them.
@internal
final class CheckedArchive {
  CheckedArchive._({
    required this.item,
    required this.version,
    required this.sha256,
    required this.matchDependencies,
    required this.manifest,
    required this.notes,
    required this.executable,
    required this.dependencies,
    required this.hashes,
    required Uint8List? bytes,
  }) : _bytes = bytes;

  /// The item it is a version of.
  final StoreItem item;

  /// The version it is the archive of.
  final StoreItemVersion version;

  /// The archive's SHA-256: what [files] reads it back from a cache by.
  final String sha256;

  /// Whether the catalog's dependencies were checked against it.
  final bool matchDependencies;

  /// Its `just_store.json`.
  final ItemManifest manifest;

  /// What the checks would tell the user.
  final List<String> notes;

  /// The files the archive marks executable.
  final Set<String> executable;

  /// The packages its pubspec depends on (SDKs aside).
  final Set<String> dependencies;

  /// Every file, by path inside the package, with its hash.
  final Map<String, String> hashes;

  /// The archive itself, kept only when there is no cache to read it back
  /// from.
  final Uint8List? _bytes;

  /// Checks [bytes], the archive of [version] of [item] whose SHA-256 is
  /// [sha256], on another isolate: every rule, every file unpacked and
  /// hashed. With a [cache] holding it, the archive itself is not kept:
  /// [files] reads it back from there.
  ///
  /// Throws what [PackageCheck.check] throws.
  static Future<CheckedArchive> check(
    Uint8List bytes,
    StoreItem item,
    StoreItemVersion version, {
    required String sha256,
    DownloadCache? cache,
    bool matchDependencies = true,
  }) async {
    final facts = await Isolate.run(
      () => _check(bytes, item, version, matchDependencies),
    );
    return CheckedArchive._(
      item: item,
      version: version,
      sha256: sha256,
      matchDependencies: matchDependencies,
      manifest: facts.manifest,
      notes: facts.notes,
      executable: facts.executable,
      dependencies: facts.dependencies,
      hashes: facts.hashes,
      // Read back from the cache when it is there (the downloader put it
      // there): only a quick look on this isolate, never a read.
      bytes: cache != null && cache.archives.fileFor(sha256).existsSync()
          ? null
          : bytes,
    );
  }

  /// Its files, by path inside the package, unpacked again on another
  /// isolate — from the archive kept, or [cache] — and handed back without
  /// a copy. Throws a [DownloadException] when the cache no longer has it.
  Future<Map<String, Uint8List>> files(DownloadCache? cache) {
    final bytes = _bytes;
    final item = this.item;
    final version = this.version;
    final sha256 = this.sha256;
    final match = matchDependencies;
    return Isolate.run(() {
      final archive = bytes ?? cache?.archive(sha256);
      if (archive == null) {
        throw DownloadException(
          'The download of ${item.name} ${version.version} is no longer in '
          'the cache. Try again.',
        );
      }
      return PackageCheck.check(
        ZipArchive.read(archive),
        item,
        version,
        matchDependencies: match,
      ).files;
    });
  }

  static ({
    ItemManifest manifest,
    List<String> notes,
    Set<String> executable,
    Set<String> dependencies,
    Map<String, String> hashes,
  })
  _check(
    Uint8List bytes,
    StoreItem item,
    StoreItemVersion version,
    bool matchDependencies,
  ) {
    final checked = PackageCheck.check(
      ZipArchive.read(bytes),
      item,
      version,
      matchDependencies: matchDependencies,
    );
    return (
      manifest: checked.manifest,
      notes: checked.notes,
      executable: checked.executable,
      dependencies: checked.dependencies,
      hashes: {
        for (final f in checked.files.entries)
          f.key: FileHashes.of(f.key, f.value),
      },
    );
  }
}

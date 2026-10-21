/// Packing a package folder into the archive a catalog pins.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../archive/zip_reader.dart';
import '../archive/zip_writer.dart';
import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import '../crypto/sha256.dart';
import '../install/package_check.dart';
import '../project/pubspec_editor.dart';
import '../project/store_project.dart';

/// A packed archive and what the catalog needs to know about it.
final class PackResult {
  /// [bytes] packed from a package described by [manifest].
  const PackResult({
    required this.bytes,
    required this.manifest,
    required this.files,
    required this.unpackedSize,
    this.warnings = const [],
  });

  /// The archive.
  final Uint8List bytes;

  /// The package's manifest.
  final ItemManifest manifest;

  /// How many files it holds.
  final int files;

  /// Their total size, in bytes.
  final int unpackedSize;

  /// Things that look wrong but don't stop it installing.
  final List<String> warnings;

  /// The archive's SHA-256.
  String get sha256 => Sha256.hexOf(bytes);

  /// The archive's usual file name, `<id>-<version>.zip`.
  String get fileName => '${manifest.id}-${manifest.version}.zip';

  /// The catalog's `items/<id>/versions/<version>.json` for this archive,
  /// downloadable from [url].
  Map<String, Object?> versionJson(String url, {DateTime? published}) =>
      compactJson({
        'version': '${manifest.version}',
        'published': published?.toUtc().toIso8601String().substring(0, 10),
        'archive': {
          'url': url,
          'sha256': sha256,
          'size': bytes.length,
          'unpackedSize': unpackedSize,
          'files': files,
        },
        'requires': {
          for (final e in manifest.requires.entries) e.key: '${e.value}',
        },
        'dependencies': {
          for (final e in manifest.dependencies.entries) e.key: '${e.value}',
        },
      });
}

/// Packs package folders.
abstract final class Packer {
  /// Top-level folders a package archive leaves out: they are for its
  /// developers, not its users.
  static const Set<String> skippedFolders = {
    'test', 'example', 'integration_test', 'doc', 'coverage', //
  };

  /// Packs [folder] (a package with a `just_store.json`) into an archive
  /// that installs: checked with the same rules the installer uses, and
  /// the same bytes on every platform — text files get LF line endings,
  /// whatever git checked out.
  ///
  /// Throws [PackageCheckException] or [StoreFormatException] when it
  /// would be refused.
  ///
  /// [excluding] is a folder inside [folder] (relative to it, with `/`)
  /// to leave out: where the archive is written, when that is inside.
  static PackResult pack(Directory folder, {String? excluding}) {
    final project = StoreProject(folder.path);
    final manifestFile = project.file(ItemManifest.fileName);
    if (!manifestFile.existsSync()) {
      throw StoreFormatException(
        'No ${ItemManifest.fileName} here.',
        file: folder.path,
      );
    }
    final ItemManifest manifest;
    try {
      manifest = ItemManifest.parse(manifestFile.readAsStringSync());
    } on StoreFormatException catch (e) {
      throw e.inFile(ItemManifest.fileName);
    }

    final files = <String, Uint8List>{};
    // Unix permissions say which files run; Windows has no such bit.
    final executable = <String>{};
    for (final entity in folder.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = project.relativeOf(entity.path);
      if (rel == null || FileHashes.isToolPath(rel)) continue;
      if (excluding != null &&
          excluding.isNotEmpty &&
          (rel == excluding || rel.startsWith('$excluding/'))) {
        continue;
      }
      final parts = rel.split('/');
      if (parts.any((p) => p.startsWith('.'))) continue;
      if (parts.length > 1 && skippedFolders.contains(parts.first)) continue;
      if (rel == 'pubspec.lock' || rel == 'pubspec_overrides.yaml') continue;
      if (_isClutter(parts.last)) continue;
      var bytes = entity.readAsBytesSync();
      if (FileHashes.isText(rel)) bytes = _lf(bytes);
      files[rel] = bytes;
      if (!Platform.isWindows && entity.statSync().mode & 0x49 != 0) {
        executable.add(rel);
      }
    }

    final zip = ZipWriter();
    files.forEach(
      (path, bytes) =>
          zip.add(path, bytes, executable: executable.contains(path)),
    );
    final bytes = zip.close();
    final item = StoreItem(
      id: manifest.id,
      name: manifest.name,
      kind: manifest.kind,
      category: manifest.category,
      versions: [
        StoreItemVersion(
          version: manifest.version,
          dependencies: manifest.dependencies,
        ),
      ],
    );
    PackageCheck.check(ZipArchive.read(bytes), item, item.versions.single);

    return PackResult(
      bytes: bytes,
      manifest: manifest,
      files: files.length,
      unpackedSize: files.values.fold(0, (s, f) => s + f.length),
      warnings: _lint(manifest, files),
    );
  }

  /// Paths that work in the author's project but break once installed.
  static List<String> _lint(ItemManifest m, Map<String, Uint8List> files) {
    final out = <String>[];
    final pubspec = PubspecEditor.parse(
      utf8.decode(files['pubspec.yaml']!),
      marker: storeBlock,
    );
    final pubDeps = pubspec.unmanaged('dependencies').keys.toSet();
    for (final dep in m.dependencies.keys) {
      if (!pubDeps.contains(dep)) {
        out.add(
          'It needs the store item "$dep", but its pubspec does not depend '
          'on it.',
        );
      }
    }
    final rootPath = RegExp(r'"(assets/[^"]*)"');
    final packagePath = RegExp(r'"packages/([a-z][a-z0-9_]*)/');
    for (final e in files.entries) {
      if (!e.key.endsWith('.json') || e.key == ItemManifest.fileName) continue;
      final String text;
      try {
        text = utf8.decode(e.value);
      } on FormatException {
        continue;
      }
      for (final match in rootPath.allMatches(text)) {
        out.add(
          '${e.key} refers to "${match[1]}", a path in your project. Inside '
          'a package write "packages/${m.id}/…".',
        );
      }
      for (final match in packagePath.allMatches(text)) {
        final other = match[1]!;
        if (other != m.id && !m.dependencies.containsKey(other)) {
          out.add(
            '${e.key} uses package "$other", which is not among its '
            'dependencies.',
          );
        }
      }
    }
    return out;
  }

  /// Files IDEs and operating systems leave in a folder: never part of a
  /// package, so left out rather than refused.
  static bool _isClutter(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.iml') ||
        lower.endsWith('.ipr') ||
        lower.endsWith('.iws') ||
        lower == 'thumbs.db' ||
        lower == 'desktop.ini';
  }

  static Uint8List _lf(Uint8List bytes) {
    if (!bytes.contains(0x0D)) return bytes;
    final out = BytesBuilder(copy: false);
    var start = 0;
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A) {
        out.add(Uint8List.sublistView(bytes, start, i));
        start = i + 1;
      }
    }
    out.add(Uint8List.sublistView(bytes, start));
    return out.takeBytes();
  }
}

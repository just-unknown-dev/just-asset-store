/// Checking a downloaded package before it may enter a project.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../archive/zip_reader.dart';
import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import '../project/pubspec_editor.dart';

/// A package the store refuses to install, with every reason found.
final class PackageCheckException implements Exception {
  /// [problems] with [item]'s package.
  const PackageCheckException(this.item, this.problems);

  /// The item's display name.
  final String item;

  /// Each problem, in a sentence.
  final List<String> problems;

  @override
  String toString() =>
      '$item cannot be installed:\n${problems.map((p) => '- $p').join('\n')}';
}

/// What a package's `pubspec.yaml` says, read without a YAML library.
final class PubspecFacts {
  PubspecFacts._(
    this.name,
    this.version,
    this.assets,
    this.hasPlugin,
    this.editor,
  );

  /// Reads [text].
  factory PubspecFacts.parse(String text) {
    String? field(String key) {
      final m = RegExp(
        '^$key\\s*:\\s*(.+?)\\s*(#.*)?\$',
        multiLine: true,
      ).firstMatch(text);
      if (m == null) return null;
      final v = m[1]!.trim();
      return (v.startsWith("'") && v.endsWith("'")) ||
              (v.startsWith('"') && v.endsWith('"'))
          ? v.substring(1, v.length - 1)
          : v;
    }

    final lines = const LineSplitter().convert(text);
    final assets = <String>[];
    var hasPlugin = false;
    final flutterAt = lines.indexWhere(
      (l) => RegExp(r'^flutter\s*:').hasMatch(l),
    );
    if (flutterAt >= 0) {
      var end = flutterAt + 1;
      while (end < lines.length &&
          (lines[end].isEmpty ||
              lines[end].startsWith(' ') ||
              lines[end].startsWith('#'))) {
        end++;
      }
      var inAssets = false;
      var assetsIndent = 0;
      for (var i = flutterAt + 1; i < end; i++) {
        final line = lines[i];
        if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
        final indent = line.length - line.trimLeft().length;
        final key = RegExp(r'^\s*([A-Za-z_-]+)\s*:').firstMatch(line);
        if (inAssets && indent > assetsIndent) {
          final item = RegExp(
            r'^\s*-\s*(?:path\s*:\s*)?(.+?)\s*(#.*)?$',
          ).firstMatch(line);
          if (item != null) {
            var v = item[1]!.trim();
            if ((v.startsWith("'") && v.endsWith("'")) ||
                (v.startsWith('"') && v.endsWith('"'))) {
              v = v.substring(1, v.length - 1);
            }
            assets.add(v);
          }
          continue;
        }
        inAssets = false;
        if (key == null) continue;
        if (key[1] == 'assets') {
          inAssets = true;
          assetsIndent = indent;
        } else if (key[1] == 'plugin') {
          hasPlugin = true;
        }
      }
    }
    return PubspecFacts._(
      field('name'),
      field('version'),
      assets,
      hasPlugin,
      PubspecEditor.parse(text, marker: storeBlock),
    );
  }

  /// The package's name.
  final String? name;

  /// Its version, as written.
  final String? version;

  /// Its `flutter: assets:` entries.
  final List<String> assets;

  /// Whether it declares a Flutter plugin (native code).
  final bool hasPlugin;

  final PubspecEditor editor;

  /// Its `dependencies`.
  Map<String, DependencySpec> get dependencies =>
      editor.unmanaged('dependencies');
}

/// A package that passed [PackageCheck.check]: its files and manifest.
final class CheckedPackage {
  /// [files] (path → bytes, at the package root) described by [manifest];
  /// those in [executable] were marked executable in the archive.
  const CheckedPackage(
    this.manifest,
    this.files, {
    this.notes = const [],
    this.executable = const {},
  });

  /// Its `just_store.json`.
  final ItemManifest manifest;

  /// Every file, by path inside the package.
  final Map<String, Uint8List> files;

  /// Things worth telling the user that don't stop the install.
  final List<String> notes;

  /// The files the archive marks executable (a Unix mode with `x`): they
  /// are installed executable on macOS and Linux.
  final Set<String> executable;

  /// The total size of its files, in bytes.
  int get size => files.values.fold(0, (sum, f) => sum + f.length);
}

/// The rules a package must follow to be installed.
abstract final class PackageCheck {
  /// Extensions a content item may hold.
  static const Set<String> contentExtensions = {
    'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', // images
    'json', 'yaml', 'yml', 'md', 'txt', 'xml', 'csv', 'svg', // data
    'tmx', 'tsx', 'tmj', 'tsj', 'tx', // Tiled
    'jsprite', 'aseprite', 'ase', 'atlas', 'fnt', // sprites, fonts
    'wav', 'mp3', 'ogg', 'flac', 'm4a', // sound
    'ttf', 'otf', 'ttc', // fonts
    'glsl', 'frag', 'vert', 'yarn', // shaders, dialogue
  };

  /// File names without an extension a package may hold at its root.
  static const Set<String> plainNames = {
    'LICENSE', 'LICENCE', 'README', 'CHANGELOG', 'NOTICE', 'AUTHORS', //
  };

  /// Top-level folders a package may never hold: native code, build hooks
  /// that run on the user's machine, scripts.
  static const Set<String> forbiddenFolders = {
    'hook', 'android', 'ios', 'macos', 'windows', 'linux', 'web', 'bin', //
    'tool', 'build',
  };

  /// The unpacked files of [zip], the archive of [version] of [item], if
  /// it follows the rules; else throws [PackageCheckException] listing
  /// every problem found.
  ///
  /// A single top-level folder holding the package (as GitHub's source
  /// archives have) is unwrapped.
  static CheckedPackage check(
    ZipArchive zip,
    StoreItem item,
    StoreItemVersion version,
  ) {
    final problems = <String>[];
    final notes = <String>[];
    final raw = <String, Uint8List>{
      for (final e in zip.files) e.path: zip.contentOf(e),
    };
    var files = _unwrap(raw);
    // The folder an archive wrapped the package in, when it did.
    final top = identical(files, raw)
        ? ''
        : '${raw.keys.first.split('/').first}/';
    final executable = {
      for (final e in zip.files)
        if (e.isExecutable &&
            e.path.startsWith(top) &&
            e.path.length > top.length)
          e.path.substring(top.length),
    };

    final pubspecBytes = files['pubspec.yaml'];
    final manifestBytes = files[ItemManifest.fileName];
    if (pubspecBytes == null) problems.add('It has no pubspec.yaml.');
    if (manifestBytes == null) {
      problems.add('It has no ${ItemManifest.fileName}.');
    }
    if (problems.isNotEmpty) {
      throw PackageCheckException(item.name, problems);
    }

    ItemManifest manifest;
    try {
      manifest = ItemManifest.parse(utf8.decode(manifestBytes!));
    } on StoreFormatException catch (e) {
      throw PackageCheckException(item.name, [
        'Its ${ItemManifest.fileName} is invalid: ${e.inFile(ItemManifest.fileName)}',
      ]);
    } on FormatException {
      throw PackageCheckException(item.name, [
        'Its ${ItemManifest.fileName} is not UTF-8 text.',
      ]);
    }
    if (manifest.id != item.id) {
      problems.add('Its manifest names "${manifest.id}", not "${item.id}".');
    }
    if (manifest.version != version.version) {
      problems.add(
        'Its manifest says version ${manifest.version}, not ${version.version}.',
      );
    }
    if (manifest.kind != item.kind) {
      problems.add(
        'Its manifest says it is ${manifest.kind.id}, not ${item.kind.id}.',
      );
    }
    if (manifest.category != item.category) {
      problems.add(
        'Its manifest puts it in "${manifest.category}", not '
        '"${item.category}".',
      );
    }

    final PubspecFacts pubspec;
    try {
      pubspec = PubspecFacts.parse(utf8.decode(pubspecBytes!));
    } on FormatException {
      throw PackageCheckException(item.name, ['Its pubspec.yaml is not text.']);
    } on PubspecEditException catch (e) {
      throw PackageCheckException(item.name, [
        'Its pubspec.yaml: ${e.message}',
      ]);
    }
    if (pubspec.name != item.id) {
      problems.add('Its pubspec names "${pubspec.name}", not "${item.id}".');
    }
    if (pubspec.version != '${version.version}') {
      problems.add(
        'Its pubspec says version ${pubspec.version}, not ${version.version}.',
      );
    }
    final Map<String, DependencySpec> deps;
    try {
      deps = pubspec.dependencies;
    } on PubspecEditException catch (e) {
      throw PackageCheckException(item.name, [
        'Its pubspec.yaml: ${e.message}',
      ]);
    }
    for (final e in deps.entries) {
      final spec = e.value;
      if (spec is PathDependency ||
          (spec is OtherDependency &&
              RegExp(r'\b(path|git)\s*:').hasMatch(spec.text))) {
        problems.add(
          'It depends on "${e.key}" by path or git. Store packages depend '
          'on versions; the store points them at installed copies.',
        );
      }
      if (item.kind == ItemKind.content &&
          !(spec is OtherDependency && spec.text.contains('sdk:'))) {
        problems.add(
          'A content item depends on nothing, but it needs "${e.key}".',
        );
      }
    }
    if (pubspec.hasPlugin) {
      if (item.kind == ItemKind.content) {
        problems.add('A content item cannot be a Flutter plugin.');
      } else {
        notes.add(
          '${item.name} is a Flutter plugin: its native code builds into the '
          'app.',
        );
      }
    }

    // Every file: a safe kind, in a place allowed for it.
    final allowed = {...contentExtensions, if (item.kind.isCode) 'dart'};
    for (final path in files.keys) {
      final parts = path.split('/');
      final name = parts.last;
      if (parts.any((p) => p.startsWith('.')) &&
          !(parts.length == 1 &&
              const {
                '.gitignore',
                '.pubignore',
                '.gitattributes',
              }.contains(name))) {
        problems.add('"$path" is hidden or inside a hidden folder.');
        continue;
      }
      // The store's own tools ship a command-line tool in bin/; only
      // official code may, never anyone else's.
      final officialTool =
          parts.first == 'bin' &&
          item.kind.isCode &&
          item.trust == TrustLevel.official;
      if (parts.length > 1 &&
          forbiddenFolders.contains(parts.first) &&
          !officialTool) {
        problems.add(
          '"$path" is in ${parts.first}/, which store packages may not have.',
        );
        continue;
      }
      if (name == 'pubspec.lock' || name == 'pubspec_overrides.yaml') {
        problems.add('"$path" must not be in a package.');
        continue;
      }
      if (parts.length == 1 && name.startsWith('.')) continue;
      final dot = name.lastIndexOf('.');
      if (dot < 0) {
        if (parts.length == 1 && plainNames.contains(name.toUpperCase())) {
          continue;
        }
        problems.add('"$path" has no file type.');
        continue;
      }
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allowed.contains(ext)) {
        problems.add(
          item.kind.isCode
              ? '"$path" is a .$ext file, which store packages may not hold.'
              : '"$path" is a .$ext file, which content items may not hold.',
        );
      }
    }

    if (item.kind == ItemKind.content) {
      _checkContent(manifest, pubspec, files, problems);
    }
    for (final preview in manifest.previews) {
      if (!files.containsKey(preview)) {
        problems.add('The preview "$preview" is missing.');
      }
    }
    if (problems.isNotEmpty) {
      throw PackageCheckException(item.name, problems);
    }
    return CheckedPackage(
      manifest,
      files,
      notes: notes,
      executable: executable,
    );
  }

  /// Content ships only what its asset folders hold, and Flutter does not
  /// look into subfolders: every file must sit directly in one of them, and
  /// the pubspec must list exactly those folders.
  static void _checkContent(
    ItemManifest manifest,
    PubspecFacts pubspec,
    Map<String, Uint8List> files,
    List<String> problems,
  ) {
    final listed = pubspec.assets.toSet();
    final declared = manifest.assetFolders.toSet();
    for (final f in declared.difference(listed)) {
      problems.add('The asset folder "$f" is not in its pubspec.');
    }
    for (final f in listed.difference(declared)) {
      problems.add('Its pubspec lists "$f", which its manifest does not.');
    }
    final meta = {'pubspec.yaml', ItemManifest.fileName, ...manifest.previews};
    final used = <String>{};
    for (final path in files.keys) {
      if (meta.contains(path) || !path.contains('/')) continue;
      final folder = path.substring(0, path.lastIndexOf('/') + 1);
      if (declared.contains(folder)) {
        used.add(folder);
      } else {
        problems.add(
          '"$path" is not directly in an asset folder, so it would not ship. '
          'Add "$folder" to content.assetFolders and the pubspec.',
        );
      }
    }
    for (final f in declared.difference(used)) {
      problems.add('The asset folder "$f" is empty.');
    }
  }

  static Map<String, Uint8List> _unwrap(Map<String, Uint8List> files) {
    if (files.containsKey('pubspec.yaml') || files.isEmpty) return files;
    final firsts = files.keys.map((p) => p.split('/').first).toSet();
    if (firsts.length != 1) return files;
    final top = '${firsts.single}/';
    if (!files.containsKey('${top}pubspec.yaml')) return files;
    return {
      for (final e in files.entries)
        if (e.key.length > top.length) e.key.substring(top.length): e.value,
    };
  }
}

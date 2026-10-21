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

  /// Reads [text]. Every line is read once, from left to right: a long
  /// line costs its length, never its square.
  factory PubspecFacts.parse(String text) {
    final lines = const LineSplitter().convert(text);

    String? field(String key) {
      for (final line in lines) {
        if (!line.startsWith(key)) continue;
        final rest = line.substring(key.length).trimLeft();
        if (!rest.startsWith(':')) continue;
        final v = _value(rest.substring(1));
        if (v.isNotEmpty) return v;
      }
      return null;
    }

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
          // `- folder/` or `- path: folder/`.
          final item = line.trimLeft();
          if (item.startsWith('-')) {
            var rest = item.substring(1).trimLeft();
            if (rest.startsWith('path')) {
              final after = rest.substring('path'.length).trimLeft();
              if (after.startsWith(':')) rest = after.substring(1);
            }
            final v = _value(rest);
            if (v.isNotEmpty) assets.add(v);
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

  /// The pubspec, for reading its dependency sections.
  final PubspecEditor editor;

  /// Its `dependencies`.
  Map<String, DependencySpec> get dependencies =>
      editor.unmanaged('dependencies');

  /// A scalar as written after its `:` or `-`: up to any `#`, trimmed, its
  /// quotes taken off.
  static String _value(String written) {
    final hash = written.indexOf('#');
    final v = (hash < 0 ? written : written.substring(0, hash)).trim();
    return v.length >= 2 &&
            ((v.startsWith("'") && v.endsWith("'")) ||
                (v.startsWith('"') && v.endsWith('"')))
        ? v.substring(1, v.length - 1)
        : v;
  }
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
    this.dependencies = const {},
  });

  /// The packages its `pubspec.yaml` depends on (SDKs aside): pub resolves
  /// each from pub.dev unless the store installs it.
  final Set<String> dependencies;

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

  /// The largest `pubspec.yaml` a package may have, in bytes.
  static const int maxPubspecBytes = 64 * 1024;

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
  ///
  /// With [matchDependencies] (unless [version] comes from no catalog: a
  /// restore from the lockfile), the store items its manifest needs must
  /// be exactly those [version] lists: the store installs what the catalog
  /// says, and pub would look on pub.dev for any other.
  static CheckedPackage check(
    ZipArchive zip,
    StoreItem item,
    StoreItemVersion version, {
    bool matchDependencies = true,
  }) {
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
    if (matchDependencies) {
      final listed = version.dependencies;
      final declared = manifest.dependencies;
      final differ = [
        for (final id in {...listed.keys, ...declared.keys})
          if ('${listed[id]}' != '${declared[id]}') id,
      ]..sort();
      if (differ.isNotEmpty) {
        problems.add(
          'Its manifest and the catalog disagree on the store items it needs '
          '(${differ.map((id) => '$id: ${declared[id] ?? 'not in the manifest'} '
              'against ${listed[id] ?? 'not in the catalog'}').join('; ')}).',
        );
      }
    }

    // A pubspec is a page of text: anything far larger is not one, and is
    // not worth the time it would take to read.
    if (pubspecBytes!.length > maxPubspecBytes) {
      throw PackageCheckException(item.name, [
        'Its pubspec.yaml is larger than ${maxPubspecBytes ~/ 1024} KiB.',
      ]);
    }
    final PubspecFacts pubspec;
    try {
      final text = utf8.decode(pubspecBytes);
      if (const LineSplitter().convert(text).any((l) => l.length > 1000)) {
        throw PackageCheckException(item.name, [
          'Its pubspec.yaml has a line longer than 1000 characters.',
        ]);
      }
      pubspec = PubspecFacts.parse(text);
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
    // What pub may fetch for it: versions from pub.dev, or an SDK. Anything
    // else — a path, git, another package server, or a form this check
    // does not know — would bring in code no catalog pinned.
    for (final e in deps.entries) {
      final spec = e.value;
      final sdk = spec is OtherDependency && _isSdk(e.key, spec.text);
      final fromPubDev =
          spec is HostedDependency &&
          (spec.url == null || _isPubDev(spec.url!));
      if (!sdk && !fromPubDev) {
        problems.add(
          'It depends on "${e.key}" by path, git or another package server. '
          'Store packages depend on versions; the store points them at '
          'installed copies.',
        );
      }
      if (item.kind == ItemKind.content && !sdk) {
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
      // Windows and macOS find `Hook/` when the toolchain asks for `hook/`:
      // folder and file names are compared as those file systems do.
      final top = parts.first.toLowerCase();
      final lowerName = name.toLowerCase();
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
          top == 'bin' && item.kind.isCode && item.trust == TrustLevel.official;
      if (parts.length > 1 && forbiddenFolders.contains(top) && !officialTool) {
        problems.add(
          '"$path" is in ${parts.first}/, which store packages may not have.',
        );
        continue;
      }
      if (lowerName == 'pubspec.lock' ||
          lowerName == 'pubspec_overrides.yaml') {
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

    // The generated registries import these: a missing one would stop the
    // editor or the game from compiling after the install.
    final ownPrefix = 'package:${manifest.id}/';
    for (final library in [
      for (final m in manifest.modules) m.library,
      for (final x in manifest.extensions) x.library,
    ]) {
      final file = 'lib/${library.substring(ownPrefix.length)}';
      if (!files.containsKey(file)) {
        problems.add('Its manifest registers $library, but it has no $file.');
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
      dependencies: {
        for (final e in deps.entries)
          if (!(e.value is OtherDependency &&
              _isSdk(e.key, (e.value as OtherDependency).text)))
            e.key,
      },
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

  /// Whether [text], the pubspec entry for the dependency [name], says only
  /// `sdk: <sdk>` (`flutter: {sdk: flutter}`, or as a block), comments
  /// aside.
  static bool _isSdk(String name, String text) {
    final body = text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'(^|\s)#.*$'), ''))
        .join(' ')
        .trim();
    final prefix = RegExp('^${RegExp.escape(name)}[ \t]*:').firstMatch(body);
    if (prefix == null) return false;
    return RegExp(
      r'^(?:\{[ \t]*sdk[ \t]*:[ \t]*[A-Za-z_]+[ \t]*\}|sdk[ \t]*:[ \t]*[A-Za-z_]+)$',
    ).hasMatch(body.substring(prefix.end).trim());
  }

  /// Whether [url], a dependency's `hosted:` server, is pub.dev.
  static bool _isPubDev(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        (uri.host == 'pub.dev' || uri.host == 'pub.dartlang.org') &&
        !uri.hasPort &&
        uri.pathSegments.every((s) => s.isEmpty);
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

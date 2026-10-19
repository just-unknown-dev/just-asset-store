// Builds real store items — pubspec, manifest, files, zipped — and a
// folder catalog listing them, for install tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_asset_store/just_asset_store.dart';

/// One item to put in a test catalog.
class TestItem {
  TestItem(
    this.id, {
    this.kind = ItemKind.content,
    this.category = 'characters',
    this.versions = const ['1.0.0'],
    this.files = const {},
    this.dependencies = const {},
    this.requires = const {},
    this.modules = const [],
    this.extensions = const [],
    this.nativePlugins = const [],
    this.trust = 'official',
    this.attribution,
    this.access = 'public',
    this.pubDependencies = const {},
    this.mutate,
  });

  final String id;
  final ItemKind kind;
  final String category;
  final List<String> versions;

  /// Extra files (path → text) beside the generated pubspec and manifest.
  /// Content defaults to one sprite pair in `sprites/`.
  final Map<String, String> files;
  final Map<String, String> dependencies;
  final Map<String, String> requires;
  final List<String> modules;
  final List<String> extensions;
  final List<String> nativePlugins;
  final String trust;
  final String? attribution;
  final String access;
  final Map<String, String> pubDependencies;

  /// Changes a version's files before zipping, to make a bad package.
  final void Function(String version, Map<String, List<int>> files)? mutate;
}

/// Writes a folder catalog of [items] into [dir]; returns its source.
FolderStoreSource buildCatalog(
  Directory dir,
  List<TestItem> items, {
  String sourceId = 'test',
}) {
  final out = <Map<String, Object?>>[];
  for (final item in items) {
    final versions = <Map<String, Object?>>[];
    for (final v in item.versions) {
      if (item.kind == ItemKind.runtimeLibrary) {
        versions.add({'version': v, 'constraint': '^$v'});
        continue;
      }
      final files = packageFiles(item, v);
      item.mutate?.call(v, files);
      final zip = ZipWriter();
      files.forEach(zip.add);
      final bytes = zip.close();
      final name = 'archives/${item.id}-$v.zip';
      File('${dir.path}/$name')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      versions.add({
        'version': v,
        if (item.access == 'public')
          'archive': {
            'url': name,
            'sha256': Sha256.hexOf(bytes),
            'size': bytes.length,
          }
        else ...{
          'access': item.access,
          'download': {'broker': 'https://store.example.com/download'},
        },
        'dependencies': item.dependencies,
        'requires': item.requires,
        'pubDependencies': item.pubDependencies,
        'nativePlugins': item.nativePlugins,
      });
    }
    out.add({
      'id': item.id,
      'name': _title(item.id),
      'kind': item.kind.id,
      'category': item.category,
      'trust': item.trust,
      'author': {'name': 'Tester'},
      'license': {'spdx': 'CC0-1.0', 'attribution': ?item.attribution},
      if (item.kind == ItemKind.runtimeLibrary) 'pub': {'package': item.id},
      'versions': versions,
    });
  }
  final categories = {for (final i in items) i.category}.toList()..sort();
  File('${dir.path}/index.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'source': {'id': sourceId, 'name': 'Test catalog'},
      'categories': [
        for (final c in categories) {'id': c, 'label': _title(c)},
      ],
      'items': out,
    }),
  );
  return FolderStoreSource(dir.path);
}

/// The files of [item] at [version], as the packer would make them.
Map<String, List<int>> packageFiles(TestItem item, String version) {
  final content = item.kind == ItemKind.content;
  final files = <String, String>{
    if (content && item.files.isEmpty) ...{
      'sprites/${item.id}.png': 'png-$version',
      'sprites/${item.id}.json':
          '{"meta": {"image": "${item.id}.png"}, "v": "$version"}',
    },
    ...item.files,
  };
  final folders = {
    for (final f in files.keys)
      if (f.contains('/')) f.substring(0, f.lastIndexOf('/') + 1),
  }.toList()..sort();
  final deps = {
    for (final e in item.dependencies.entries) e.key: e.value,
    for (final e in item.pubDependencies.entries) e.key: e.value,
  };
  final pubspec = StringBuffer()
    ..writeln('name: ${item.id}')
    ..writeln('version: $version')
    ..writeln('environment:')
    ..writeln('  sdk: ^3.0.0');
  if (deps.isNotEmpty) {
    pubspec.writeln('dependencies:');
    deps.forEach((k, v) => pubspec.writeln("  $k: '$v'"));
  }
  if (content) {
    pubspec
      ..writeln('flutter:')
      ..writeln('  assets:');
    for (final f in folders) {
      pubspec.writeln('    - $f');
    }
  }
  final manifest = {
    'schema': 1,
    'id': item.id,
    'name': _title(item.id),
    'version': version,
    'kind': item.kind.id,
    'category': item.category,
    'dependencies': item.dependencies,
    if (item.modules.isNotEmpty)
      'editor': {
        'modules': [
          for (final m in item.modules)
            {'library': 'package:${item.id}/editor.dart', 'class': m},
        ],
        if (item.kind == ItemKind.kit) 'editorOnlyLibraries': ['editor.dart'],
      },
    if (item.extensions.isNotEmpty)
      'runtime': {
        'extensions': [
          for (final x in item.extensions)
            {'library': 'package:${item.id}/${item.id}.dart', 'const': x},
        ],
        'setup': {'snippet': '// set up ${item.id}'},
      },
    if (content) 'content': {'assetFolders': folders},
  };
  return {
    'pubspec.yaml': utf8.encode('$pubspec'),
    ItemManifest.fileName: utf8.encode(jsonEncode(manifest)),
    for (final e in files.entries) e.key: utf8.encode(e.value),
  };
}

/// A pub runner that records calls and succeeds unless told otherwise.
class FakePub implements PubRunner {
  final List<String> calls = [];
  PubResult next = const PubResult(0, 'Got dependencies!', '');

  @override
  Future<PubResult> get(String projectRoot, {bool offline = false}) async {
    calls.add(offline ? 'get --offline' : 'get');
    return next;
  }
}

/// Every file under [dir] (the project), by relative path, except the
/// store's scratch folder and the trash: what must come back byte for byte
/// after a rollback.
Map<String, Uint8List> snapshot(Directory dir) {
  final out = <String, Uint8List>{};
  final base = dir.absolute.path.replaceAll(r'\', '/');
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    final rel = f.absolute.path
        .replaceAll(r'\', '/')
        .substring(base.length + 1);
    if (rel.startsWith('.dart_tool/just_core_cli') ||
        rel.startsWith('.editor_trash')) {
      continue;
    }
    out[rel] = f.readAsBytesSync();
  }
  return out;
}

String _title(String id) => id
    .split(RegExp('[_-]'))
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

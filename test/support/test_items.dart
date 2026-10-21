// Real store items in memory — pubspec, manifest, files — for tests that
// run on every platform.
import 'dart:convert';

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
    'name': titleOf(item.id),
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

/// [id] as a display name: `just_art_knight` → `Just Art Knight`.
String titleOf(String id) => id
    .split(RegExp('[_-]'))
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

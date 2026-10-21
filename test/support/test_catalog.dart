// A folder catalog of real store items, zipped, for install tests; a fake
// pub; and project snapshots. The items themselves are in test_items.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_asset_store/just_asset_store.dart';

import 'test_items.dart';

export 'test_items.dart';

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
      'name': titleOf(item.id),
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
        for (final c in categories) {'id': c, 'label': titleOf(c)},
      ],
      'items': out,
    }),
  );
  return FolderStoreSource(dir.path);
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

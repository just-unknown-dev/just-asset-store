/// A package's folder on disk, as its maker has it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';

import 'temp_project.dart';
import 'test_catalog.dart';

/// A package folder on disk for [item], with text files in [eol] endings.
Directory packageFolder(
  TestItem item, {
  String eol = '\n',
  Map<String, String> extra = const {},
}) {
  final dir = tempDir('pkg');
  final files = packageFiles(item, item.versions.first);
  files.forEach((path, bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (FileHashes.isText(path)) text = text.replaceAll('\n', eol);
    File('${dir.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  });
  writeFiles(dir, {
    '.dart_tool/package_config.json': '{}',
    '.git/HEAD': 'ref',
    'test/x_test.dart': '',
    'pubspec.lock': '',
    'just_art_knight.iml': '<module/>',
    'Thumbs.db': 'x',
    ...extra,
  });
  return dir;
}

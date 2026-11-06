// An installed item's folder, hashed file by file.
@TestOn('vm')
library;

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';

void main() {
  test('of a folder skips tool folders', () {
    final dir = tempDir('hashes');
    writeFiles(dir, {
      'pubspec.yaml': 'name: x\n',
      'assets/a.json': '{}',
      '.dart_tool/package_config.json': '{}',
      'build/out.txt': 'x',
      'pubspec.lock': '',
    });
    expect(FolderHashes.of(dir).keys.toList(), [
      'assets/a.json',
      'pubspec.yaml',
    ]);
  });
}

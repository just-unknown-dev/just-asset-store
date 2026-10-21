// One version everywhere it is written: the pubspec, the package's own
// just_store.json, the changelog, and what the store stamps its files with.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  test('the pubspec, just_store.json and the changelog agree', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(justAssetStoreVersion, version);
    expect(storeGenerator, 'just_asset_store $version');
    expect(HttpStoreSource.userAgent, startsWith('just_asset_store/$version '));

    final manifest =
        jsonDecode(File(ItemManifest.fileName).readAsStringSync())
            as Map<String, Object?>;
    expect(manifest['version'], version);

    final changelog = File('CHANGELOG.md').readAsLinesSync();
    expect(
      changelog.firstWhere((l) => l.startsWith('## ')),
      '## $version',
      reason: 'the newest entry is this version',
    );
  });
}

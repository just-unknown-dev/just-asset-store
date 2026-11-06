// Where the store keeps per-user files.
@TestOn('vm')
library;

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  test('StorePaths', () {
    final dir = StorePaths.defaultCacheDir(
      environment: {
        'LOCALAPPDATA': r'C:\Users\x\AppData\Local',
        'HOME': '/home/x',
      },
    );
    expect(dir, endsWith('just_asset_store'));
    expect(dir, isNot(contains(r'\')));
  });
}

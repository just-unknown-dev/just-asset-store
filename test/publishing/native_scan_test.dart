// Which packages bring native code, as their pubspecs tell.
@TestOn('vm')
library;

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a Flutter plugin, or a package with build hooks, brings native code',
    () {
      expect(
        NativeScan.isNativePubspec('cam', {
          'flutter': {
            'plugin': {'platforms': {}},
          },
        }),
        isTrue,
      );
      expect(
        NativeScan.isNativePubspec('sqlite3', {
          'dependencies': {'hooks': '^1.0.0'},
        }),
        isTrue,
      );
      expect(
        NativeScan.isNativePubspec('old_style', {
          'dependencies': {'native_assets_cli': '^0.9.0'},
        }),
        isTrue,
      );
      // The libraries hooks are written with have none of their own.
      for (final name in NativeScan.hookLibraries) {
        expect(
          NativeScan.isNativePubspec(name, {
            'dependencies': {'hooks': '^1.0.0'},
          }),
          isFalse,
          reason: name,
        );
      }
      expect(
        NativeScan.isNativePubspec('path', {
          'dependencies': {'meta': '^1.0.0'},
        }),
        isFalse,
      );
      expect(NativeScan.isNativePubspec('x', 'not a map'), isFalse);
    },
  );
}

// The example runs, on every platform, and says what it should.
import 'dart:async';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../example/just_asset_store_example.dart' as example;

void main() {
  test('the example checks the package and records it', () {
    final printed = <String>[];
    runZoned(
      example.main,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    expect(
      printed.first,
      matches(r'^Knight 1\.0\.0: 3 files, \d+ bytes, sprites/$'),
    );
    final lock = StoreLock.parse(printed.last);
    expect(lock.sources.single.id, 'example');
    expect(lock.items['just_art_knight']!.origin, ItemOrigin.vendored);
  });
}

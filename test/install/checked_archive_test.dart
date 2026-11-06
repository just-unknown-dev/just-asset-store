// A checked archive, as an install keeps it until it is staged.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:just_asset_store/src/install/checked_archive.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';
import '../support/test_catalog.dart';

void main() {
  late StoreItem item;
  late StoreItemVersion version;
  late Uint8List bytes;

  setUp(() async {
    final source = buildCatalog(tempDir('catalog'), [
      TestItem('just_art_knight'),
    ]);
    item = (await source.fetchIndex()).index.items.single;
    version = item.latest!;
    bytes = await source.readBytes(source.resolve(version.archive!.url));
  });

  test('is checked and hashed as the package check sees it', () async {
    final checked = await CheckedArchive.check(
      bytes,
      item,
      version,
      sha256: version.archive!.sha256,
    );
    final package = PackageCheck.check(ZipArchive.read(bytes), item, version);
    expect(checked.manifest.id, package.manifest.id);
    expect(checked.hashes, {
      for (final f in package.files.entries)
        f.key: FileHashes.of(f.key, f.value),
    });
    expect(await checked.files(null), package.files);
  });

  test(
    'with a cache, keeps no copy: its files are read back from there',
    () async {
      final cache = DownloadCache(tempDir('cache').path);
      final sha = version.archive!.sha256;
      cache.putArchive(sha, bytes);
      final checked = await CheckedArchive.check(
        bytes,
        item,
        version,
        sha256: sha,
        cache: cache,
      );
      expect((await checked.files(cache)).keys, contains('just_store.json'));
      cache.clear();
      await expectLater(
        checked.files(cache),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('no longer in the cache'),
          ),
        ),
      );
    },
  );

  test('refuses what the package check refuses', () async {
    final bad = buildCatalog(tempDir('bad'), [
      TestItem(
        'just_art_bad',
        mutate: (v, files) => files['sprites/evil.exe'] = [0x4d, 0x5a],
      ),
    ]);
    final it = (await bad.fetchIndex()).index.items.single;
    final v = it.latest!;
    await expectLater(
      CheckedArchive.check(
        await bad.readBytes(bad.resolve(v.archive!.url)),
        it,
        v,
        sha256: v.archive!.sha256,
      ),
      throwsA(isA<PackageCheckException>()),
    );
  });
}

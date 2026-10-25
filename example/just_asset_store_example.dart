// Reading a catalog, pinning an item's archive and checking the package in
// it, then recording it as installed. All of this runs on every platform,
// the web included; on a machine with files, `AssetStore` does the same for
// a real project (see the README).
import 'dart:convert';

import 'package:just_asset_store/just_asset_store.dart';

void main() {
  // A creator's package, zipped as `just store pack` would: its pubspec, its
  // just_store.json and its assets.
  final manifest = {
    'schema': 1,
    'id': 'just_art_knight',
    'name': 'Knight',
    'version': '1.0.0',
    'kind': 'content',
    'category': 'characters',
    'content': {
      'assetFolders': ['sprites/'],
    },
  };
  final archive =
      (ZipWriter()
            ..add(
              'pubspec.yaml',
              utf8.encode(
                'name: just_art_knight\n'
                'version: 1.0.0\n'
                'environment:\n'
                '  sdk: ^3.0.0\n'
                'flutter:\n'
                '  assets:\n'
                '    - sprites/\n',
              ),
            )
            ..add(ItemManifest.fileName, utf8.encode(jsonEncode(manifest)))
            ..add('sprites/knight.png', [0x89, 0x50, 0x4e, 0x47]))
          .close();

  // The catalog offering it, which pins the archive by size and SHA-256.
  final catalog = StoreIndex.parse(
    jsonEncode({
      'schema': 1,
      'source': {'id': 'example', 'name': 'Example catalog'},
      'categories': [
        {'id': 'characters', 'label': 'Characters'},
      ],
      'items': [
        {
          'id': 'just_art_knight',
          'name': 'Knight',
          'kind': 'content',
          'category': 'characters',
          'license': {'spdx': 'CC0-1.0'},
          'versions': [
            {
              'version': '1.0.0',
              'archive': {
                'url': 'just_art_knight-1.0.0.zip',
                'sha256': Sha256.hexOf(archive),
                'size': archive.length,
              },
            },
          ],
        },
      ],
    }),
  );

  final item = catalog.item('just_art_knight')!;
  final version = item.bestFor(VersionConstraint.parse('^1.0.0'))!;
  final pin = version.archive!;
  if (pin.size != archive.length || pin.sha256 != Sha256.hexOf(archive)) {
    throw StateError('The archive is not the one the catalog pins.');
  }

  // Every rule a package must pass before it may enter a project.
  try {
    final package = PackageCheck.check(ZipArchive.read(archive), item, version);
    print(
      '${item.name} ${version.version}: ${package.files.length} files, '
      '${package.size} bytes, ${package.manifest.assetFolders.join(', ')}',
    );
  } on PackageCheckException catch (e) {
    print(e);
    return;
  }

  // What the project's just_store.lock.json records once it is installed.
  final lock = StoreLock()
      .withSource(
        LockedSource(catalog.source.id, 'https://example.com/index.json'),
      )
      .withItem(
        item.id,
        LockedItem(
          version: '${version.version}',
          kind: item.kind,
          origin: ItemOrigin.vendored,
          category: item.category,
          // Its folder: content goes in packages/, editor tools and kits in
          // plugins/.
          path: '${item.kind.installFolder}/${item.category}/${item.id}',
          source: catalog.source.id,
          archive: LockedArchive(pin.url, pin.sha256),
        ),
      );
  print(lock.toText());
}

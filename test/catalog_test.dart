// index.json and just_store.json: what reads, what is refused (with where),
// and that writing then reading gives the same thing.
import 'dart:convert';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

const String sha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> index({List<Map<String, Object?>>? items}) => {
  'schema': 1,
  'source': {'id': 'just-official', 'name': 'Just Asset Store'},
  'categories': [
    {'id': 'characters', 'label': 'Characters', 'order': 10},
    {'id': 'editors', 'label': 'Editor tools', 'order': 50},
    {'id': 'libraries', 'label': 'Libraries', 'order': 90},
  ],
  'items': items ?? [knight(), spriteEditor(), tiledLib()],
};

Map<String, Object?> knight({Map<String, Object?> extra = const {}}) => {
  'id': 'just_art_knight',
  'name': 'Knight',
  'kind': 'content',
  'category': 'characters',
  'summary': 'A pixel knight with run and attack clips.',
  'tags': ['pixel-art', 'hero'],
  'author': {'name': 'Just'},
  'license': {'spdx': 'CC0-1.0'},
  'thumbnail': 'thumbs/just_art_knight.png',
  'versions': [
    {
      'version': '1.0.0',
      'archive': {
        'url': 'archives/just_art_knight-1.0.0.zip',
        'sha256': sha,
        'size': 1234,
      },
    },
    {
      'version': '1.1.0',
      'archive': {
        'url':
            'https://github.com/just-unknown-dev/store/releases/download/k/k.zip',
        'sha256': sha,
        'size': 1300,
      },
      'requires': {'just_game_engine': '^2.0.0'},
    },
    {
      'version': '1.2.0',
      'yanked': true,
      'archive': {'url': 'a.zip', 'sha256': sha, 'size': 1},
    },
  ],
  ...extra,
};

Map<String, Object?> spriteEditor() => {
  'id': 'just_sprite_editor',
  'name': 'Sprite Studio',
  'kind': 'editor-extension',
  'category': 'editors',
  'versions': [
    {
      'version': '0.1.0',
      'archive': {'url': 'a.zip', 'sha256': sha, 'size': 10},
      'dependencies': {'just_game_engine_editor': '^0.1.0'},
      'nativePlugins': ['file_selector'],
    },
  ],
};

Map<String, Object?> tiledLib() => {
  'id': 'just_tiled',
  'name': 'Tiled maps',
  'kind': 'runtime-library',
  'category': 'libraries',
  'pub': {'package': 'just_tiled'},
  'versions': [
    {'version': '0.4.1', 'constraint': '^0.4.1'},
  ],
};

StoreIndex read(Map<String, Object?> json) =>
    StoreIndex.parse(jsonEncode(json));

Matcher failsAt(String where) =>
    throwsA(isA<StoreFormatException>().having((e) => e.where, 'where', where));

void main() {
  group('StoreIndex', () {
    test('reads a catalog', () {
      final catalog = read(index());
      expect(catalog.source.id, 'just-official');
      expect(catalog.items.map((i) => i.id), [
        'just_art_knight',
        'just_sprite_editor',
        'just_tiled',
      ]);
      final k = catalog.item('just_art_knight')!;
      expect(k.kind, ItemKind.content);
      expect(k.isOfficial, isTrue);
      expect(k.pricing.isFree, isTrue);
      expect('${k.latest!.version}', '1.1.0', reason: '1.2.0 is yanked');
      expect(k.available.length, 2);
      expect(
        '${k.bestFor(VersionConstraint.parse('^1.0.0'))!.version}',
        '1.1.0',
      );
      expect(k.matches('PIXEL'), isTrue);
      expect(k.matches('dragon'), isFalse);
      expect(catalog.item('just_tiled')!.pubPackage, 'just_tiled');
      expect(catalog.item('just_sprite_editor')!.latest!.nativePlugins, [
        'file_selector',
      ]);
    });

    test('categories are sorted by order', () {
      final json = index();
      (json['categories'] as List).insert(0, {
        'id': 'ui',
        'label': 'UI',
        'order': 70,
      });
      expect(read(json).categories.map((c) => c.id), [
        'characters',
        'editors',
        'ui',
        'libraries',
      ]);
    });

    test('writing and reading back gives the same catalog', () {
      final catalog = read(index());
      final again = read(catalog.toJson());
      expect(canonicalJson(again.toJson()), canonicalJson(catalog.toJson()));
    });

    test('unknown fields are ignored, so newer catalogs still read', () {
      final json = index(
        items: [
          knight(extra: {'futureField': 42}),
        ],
      )..['alsoNew'] = true;
      expect(read(json).items.single.id, 'just_art_knight');
    });

    test('reserved fields for community and paid items', () {
      final json = index(
        items: [
          knight(
            extra: {
              'publisher': 'pixel_folk',
              'trust': 'community',
              'stats': {'downloads': 12, 'likes': 3},
              'pricing': {
                'model': 'paid',
                'amount': 499,
                'currency': 'USD',
                'licence': 'per-seat',
              },
              'versions': [
                {
                  'version': '2.0.0',
                  'access': 'entitled',
                  'download': {'broker': 'https://store.example.com/download'},
                },
              ],
            },
          ),
        ],
      );
      final item = read(json).items.single;
      expect(item.trust, TrustLevel.community);
      expect(item.isOfficial, isFalse);
      expect(item.stats!.downloads, 12);
      expect(item.pricing.amount, 499);
      expect(item.latest!.access, AccessLevel.entitled);
      expect(item.latest!.archive, isNull);
      expect(item.latest!.broker, 'https://store.example.com/download');
    });

    test('a newer format asks for a newer store', () {
      expect(() => read(index()..['schema'] = 2), failsAt('schema'));
    });

    test('refusals say where', () {
      expect(
        () => read(
          index(
            items: [
              knight(extra: {'id': 'Bad-Id'}),
            ],
          ),
        ),
        failsAt('items[0].id'),
      );
      // A kind this version doesn't know is a newer catalog's: left out,
      // not a reason to refuse the rest.
      expect(
        read(
          index(
            items: [
              knight(extra: {'kind': 'plugin'}),
            ],
          ),
        ).skipped,
        ['just_art_knight'],
      );
      expect(
        () => read(
          index(
            items: [
              knight(extra: {'kind': 3}),
            ],
          ),
        ),
        failsAt('items[0].kind'),
      );
      expect(
        () => read(
          index(
            items: [
              knight(extra: {'category': 'nope'}),
            ],
          ),
        ),
        failsAt('items[0].category'),
      );
      expect(
        () => read(
          index(
            items: [
              knight(
                extra: {
                  'versions': [
                    {
                      'version': '1.0.0',
                      'archive': {'url': 'a.zip', 'sha256': 'abc', 'size': 1},
                    },
                  ],
                },
              ),
            ],
          ),
        ),
        failsAt('items[0].versions[0].archive.sha256'),
      );
      expect(
        () => read(
          index(
            items: [
              knight(
                extra: {
                  'versions': [
                    {'version': '1.0.0'},
                  ],
                },
              ),
            ],
          ),
        ),
        failsAt('items[0].versions[0].archive'),
      );
      expect(
        () => read(index(items: [knight(), knight()])),
        failsAt('items[1].id'),
      );
      expect(
        () => read(
          index(
            items: [
              {...tiledLib()}..remove('pub'),
            ],
          ),
        ),
        failsAt('items[0].pub'),
      );
    });

    test('archive URLs stay beside index.json or use http(s)', () {
      for (final url in [
        '../x.zip',
        '/abs/x.zip',
        'file:///c:/x.zip',
        r'a\b.zip',
      ]) {
        expect(
          () => read(
            index(
              items: [
                knight(
                  extra: {
                    'versions': [
                      {
                        'version': '1.0.0',
                        'archive': {'url': url, 'sha256': sha, 'size': 1},
                      },
                    ],
                  },
                ),
              ],
            ),
          ),
          throwsA(isA<StoreFormatException>()),
          reason: url,
        );
      }
    });

    test('not JSON at all', () {
      expect(
        () => StoreIndex.parse('{oops'),
        throwsA(isA<StoreFormatException>()),
      );
      expect(
        () => StoreIndex.parse('[]'),
        throwsA(isA<StoreFormatException>()),
      );
    });
  });

  group('ItemManifest', () {
    Map<String, Object?> kit() => {
      'schema': 1,
      'id': 'just_platformer_kit',
      'name': 'Platformer Kit',
      'version': '0.1.0',
      'kind': 'kit',
      'category': 'kits',
      'license': {'spdx': 'BSD-3-Clause', 'file': 'LICENSE'},
      'requires': {'just_game_engine': '^2.0.0'},
      'dependencies': {'just_game_engine_editor': '^0.1.0'},
      'editor': {
        'modules': [
          {
            'library': 'package:just_platformer_kit/editor.dart',
            'class': 'PlatformerModule',
            'order': 10,
          },
        ],
        'editorOnlyLibraries': ['editor.dart', 'src/editor/'],
      },
      'runtime': {
        'extensions': [
          {
            'library': 'package:just_platformer_kit/just_platformer_kit.dart',
            'const': 'PlatformerKit.extension',
          },
        ],
        'componentTypes': ['PlayerControlComponent'],
        'setup': {
          'file': 'lib/game/boot/game_boot.dart',
          'snippet': 'PlatformerKit.registerSystems(world);',
        },
      },
    };

    ItemManifest readManifest(Map<String, Object?> json) =>
        ItemManifest.parse(jsonEncode(json));

    test('reads a kit', () {
      final m = readManifest(kit());
      expect(m.kind, ItemKind.kit);
      expect(m.modules.single.className, 'PlatformerModule');
      expect(m.modules.single.order, 10);
      expect(m.extensions.single.constant, 'PlatformerKit.extension');
      expect(m.extensions.single.order, 100);
      expect(m.isEditorOnly, isFalse);
      expect(m.setupSnippet, contains('registerSystems'));
      expect(
        canonicalJson(readManifest(m.toJson()).toJson()),
        canonicalJson(m.toJson()),
      );
    });

    test('an editor extension is editor-only', () {
      final m = readManifest({
        'schema': 1,
        'id': 'just_sprite_editor',
        'name': 'Sprite Studio',
        'version': '0.1.0',
        'kind': 'editor-extension',
        'category': 'editors',
        'editor': {
          'modules': [
            {
              'library': 'package:just_sprite_editor/editor.dart',
              'class': 'SpriteStudioModule',
            },
          ],
        },
      });
      expect(m.isEditorOnly, isTrue);
    });

    test('content lists its asset folders', () {
      final m = readManifest({
        'schema': 1,
        'id': 'just_art_knight',
        'name': 'Knight',
        'version': '1.0.0',
        'kind': 'content',
        'category': 'characters',
        'content': {
          'assetFolders': ['sprites/', 'sprites/attack/'],
          'entryPoints': [
            {'path': 'sprites/knight.json', 'kind': 'sprite'},
          ],
        },
      });
      expect(m.assetFolders, ['sprites/', 'sprites/attack/']);
      expect(m.entryPoints.single.kind, 'sprite');
    });

    test('nothing that could inject code into generated files', () {
      for (final bad in [
        'PlatformerModule(); import "dart:io"; //',
        'A B',
        'class',
        r'a\u0000',
        '',
      ]) {
        final json = kit();
        ((json['editor'] as Map)['modules'] as List)[0] = {
          'library': 'package:just_platformer_kit/editor.dart',
          'class': bad,
        };
        expect(
          () => readManifest(json),
          throwsA(isA<StoreFormatException>()),
          reason: bad,
        );
      }
    });

    test('libraries must belong to the package itself', () {
      for (final lib in [
        'package:other/editor.dart',
        'package:just_platformer_kit/../x.dart',
        'package:just_platformer_kit/editor.txt',
        'dart:io',
        'file:///c:/evil.dart',
        // Nothing that ends the import's string or starts a directive.
        "package:just_platformer_kit/a.dart' if (dart.library.io) 'b.dart",
        "package:just_platformer_kit/a.dart'; import 'b.dart",
        'package:just_platformer_kit/a b.dart',
        r'package:just_platformer_kit/$a.dart',
      ]) {
        final json = kit();
        ((json['runtime'] as Map)['extensions'] as List)[0] = {
          'library': lib,
          'const': 'X.y',
        };
        expect(
          () => readManifest(json),
          throwsA(isA<StoreFormatException>()),
          reason: lib,
        );
      }
    });

    test('content can register no code, and must list folders', () {
      final json = kit()..['kind'] = 'content';
      expect(() => readManifest(json), throwsA(isA<StoreFormatException>()));
      expect(
        () => readManifest({
          'schema': 1,
          'id': 'just_art_x',
          'name': 'X',
          'version': '1.0.0',
          'kind': 'content',
          'category': 'characters',
        }),
        throwsA(isA<StoreFormatException>()),
      );
      expect(
        () => readManifest({
          'schema': 1,
          'id': 'just_art_x',
          'name': 'X',
          'version': '1.0.0',
          'kind': 'content',
          'category': 'characters',
          'content': {
            'assetFolders': ['sprites'],
          },
        }),
        throwsA(isA<StoreFormatException>()),
        reason: 'folders end in /',
      );
    });

    test('runtime libraries carry no manifest', () {
      expect(
        () => readManifest(kit()..['kind'] = 'runtime-library'),
        throwsA(isA<StoreFormatException>()),
      );
    });
  });

  group('StoreNames', () {
    test('item ids follow pub package names', () {
      expect(StoreNames.isId('just_art_knight'), isTrue);
      for (final bad in ['Just', '1abc', 'a-b', 'class', '', 'a' * 65]) {
        expect(StoreNames.isId(bad), isFalse, reason: bad);
      }
    });

    test('dotted identifiers', () {
      expect(StoreNames.isDottedIdentifier('PlatformerKit.extension'), isTrue);
      expect(StoreNames.isDottedIdentifier(r'_Private$1'), isTrue);
      expect(StoreNames.isDottedIdentifier('a.'), isFalse);
      expect(StoreNames.isDottedIdentifier('a.new'), isFalse);
    });
  });

  group('what a catalog may not slip in', () {
    test('control characters in what is shown', () {
      for (final extra in <Map<String, Object?>>[
        {'name': 'Knight\u001b[2K'},
        {'summary': 'ok\u009b31m'},
        {
          'tags': ['hero\u202e'],
        },
        {
          'author': {'name': 'Ju\u0007st'},
        },
        {'description': 'clear\u001b[H'},
      ]) {
        expect(
          () => read(index(items: [knight(extra: extra)])),
          throwsA(isA<StoreFormatException>()),
          reason: '$extra',
        );
      }
      expect(
        () => ItemManifest.parse(
          jsonEncode({
            'schema': 1,
            'id': 'just_kit',
            'name': 'Kit\u001b]0;pwned\u0007',
            'version': '1.0.0',
            'kind': 'kit',
            'category': 'kits',
          }),
        ),
        throwsA(isA<StoreFormatException>()),
      );
      // Line breaks and tabs are text, where text has lines.
      final ok = read(
        index(
          items: [
            knight(extra: {'description': 'Two\nlines\tand a tab.'}),
          ],
        ),
      );
      expect(ok.items.single.description, 'Two\nlines\tand a tab.');
    });

    test('pictures on the web or beside the catalog, not files elsewhere', () {
      for (final extra in <Map<String, Object?>>[
        {'thumbnail': 'file:///C:/Windows/win.ini'},
        {'thumbnail': '//attacker.example/share/x.png'},
        {'thumbnail': '../../x.png'},
        {
          'previews': ['file://attacker.example/s/x.png'],
        },
      ]) {
        expect(
          () => read(index(items: [knight(extra: extra)])),
          throwsA(isA<StoreFormatException>()),
          reason: '$extra',
        );
      }
    });

    test("a runtime library's package is the one its id names", () {
      final lib = tiledLib()..['pub'] = {'package': 'forge2d'};
      expect(
        () => read(index(items: [knight(), spriteEditor(), lib])),
        throwsA(isA<StoreFormatException>()),
      );
    });
  });

  test('canonicalJson sorts keys at every depth and ends in a newline', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': {
          'd': 1,
          'c': [
            {'z': 1, 'y': 2},
          ],
        },
      }),
      '{\n  "a": {\n    "c": [\n      {\n        "y": 2,\n        "z": 1\n      }\n    ],\n    "d": 1\n  },\n  "b": 1\n}\n',
    );
  });
}

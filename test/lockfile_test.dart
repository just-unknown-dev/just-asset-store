// The lockfile, `just_store.lock.json`: read, written and edited in memory.
import 'dart:convert';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  final hash = Sha256.hexOf(utf8.encode('x'));
  StoreLock sample() => StoreLock(
    sources: const [LockedSource('just-official', 'https://e.com/index.json')],
    items: {
      'just_tiled': const LockedItem(
        version: '^0.4.1',
        kind: ItemKind.runtimeLibrary,
        origin: ItemOrigin.hosted,
      ),
      'just_art_knight': LockedItem(
        version: '1.2.0',
        kind: ItemKind.content,
        origin: ItemOrigin.vendored,
        category: 'characters',
        path: 'packages/characters/just_art_knight',
        source: 'just-official',
        archive: LockedArchive('https://e.com/k.zip', hash),
        installedAt: DateTime.utc(2026, 10, 7),
        files: {'pubspec.yaml': hash},
      ),
      'just_sprite_editor': const LockedItem(
        version: '0.1.0',
        kind: ItemKind.editorExtension,
        origin: ItemOrigin.linked,
        path: 'packages/just_sprite_editor',
        registerModules: false,
        entitlement: 'order-123',
      ),
    },
  );

  test('round-trips, sorted, as canonical JSON', () {
    final text = sample().toText();
    final again = StoreLock.parse(text);
    expect(again.toText(), text);
    expect(again.items.keys.toList(), [
      'just_art_knight',
      'just_sprite_editor',
      'just_tiled',
    ]);
    expect(again.items['just_sprite_editor']!.registerModules, isFalse);
    expect(again.items['just_sprite_editor']!.isDevDependency, isTrue);
    expect(again.items['just_art_knight']!.files['pubspec.yaml'], hash);
    expect(
      again.items['just_art_knight']!.installedAt,
      DateTime.utc(2026, 10, 7),
    );
    expect(text, endsWith('}\n'));
    expect(text, isNot(contains('\r')));
  });

  test('edits return copies', () {
    final lock = sample();
    final fewer = lock.without('just_tiled');
    expect(lock.items, contains('just_tiled'));
    expect(fewer.items, isNot(contains('just_tiled')));
    final more = fewer.withSource(
      const LockedSource('studio', 'D:/packs/index.json'),
    );
    expect(more.sources.map((s) => s.id), ['just-official', 'studio']);
  });

  test('refuses a damaged lockfile', () {
    expect(
      () => StoreLock.parse('{"schema": 1, "items": {"Bad": {}}}'),
      throwsA(isA<StoreFormatException>()),
    );
    expect(
      () => StoreLock.parse(
        '{"schema": 1, "items": {"a": {"version": "1.0.0", "kind": "content", "origin": "vendored"}}}',
      ),
      throwsA(isA<StoreFormatException>()),
      reason: 'a vendored item records its folder',
    );
    expect(
      () => StoreLock.parse('{"schema": 9}'),
      throwsA(isA<StoreFormatException>()),
    );
  });

  test("a vendored item's folder is the one the store gives it", () {
    String vendored(String path, {String sha = ''}) => jsonEncode({
      'schema': 1,
      'items': {
        'just_art_knight': {
          'version': '1.0.0',
          'kind': 'content',
          'origin': 'vendored',
          'category': 'characters',
          'path': path,
          if (sha.isNotEmpty) 'archive': {'url': 'k.zip', 'sha256': sha},
        },
      },
    });
    expect(
      StoreLock.parse(
        vendored('packages/characters/just_art_knight'),
      ).items['just_art_knight']!.path,
      'packages/characters/just_art_knight',
    );
    // Restore, update and uninstall move this folder: never one elsewhere.
    for (final path in [
      '../escaped/just_art_knight',
      'packages/characters/../../../x',
      'lib',
      'packages/props/just_art_knight',
      'C:/Users',
    ]) {
      expect(
        () => StoreLock.parse(vendored(path)),
        throwsA(isA<StoreFormatException>()),
        reason: path,
      );
    }
    expect(
      () => StoreLock.parse(
        vendored('packages/characters/just_art_knight', sha: 'not-a-hash'),
      ),
      throwsA(isA<StoreFormatException>()),
    );
    // A developer's own checkout may be anywhere: the store never moves it.
    expect(
      StoreLock.parse(
        jsonEncode({
          'schema': 1,
          'items': {
            'just_sprite_editor': {
              'version': '0.1.0',
              'kind': 'editor-extension',
              'origin': 'linked',
              'path': '../just_sprite_editor',
            },
          },
        }),
      ).items['just_sprite_editor']!.path,
      '../just_sprite_editor',
    );
  });

  test("a vendored item's folder depends on its kind", () {
    String vendored(String kind, String category, String id, String path) =>
        jsonEncode({
          'schema': 1,
          'items': {
            id: {
              'version': '1.0.0',
              'kind': kind,
              'origin': 'vendored',
              'category': category,
              'path': path,
            },
          },
        });
    Matcher refused(String want) => throwsA(
      isA<StoreFormatException>().having(
        (e) => e.message,
        'message',
        contains('lives in "$want"'),
      ),
    );

    // Editor extensions and kits are plugins, in plugins/.
    for (final (kind, category, id) in [
      ('kit', 'kits', 'just_kit'),
      ('editor-extension', 'editors', 'just_tool'),
    ]) {
      expect(
        StoreLock.parse(
          vendored(kind, category, id, 'plugins/$category/$id'),
        ).items[id]!.path,
        'plugins/$category/$id',
        reason: kind,
      );
      expect(
        () => StoreLock.parse(
          vendored(kind, category, id, 'packages/$category/$id'),
        ),
        refused('plugins/$category/$id'),
        reason: kind,
      );
    }
    // Content stays in packages/.
    expect(
      () => StoreLock.parse(
        vendored(
          'content',
          'characters',
          'just_art_knight',
          'plugins/characters/just_art_knight',
        ),
      ),
      refused('packages/characters/just_art_knight'),
    );
    // A pub.dev library or a template is never copied in.
    for (final kind in ['runtime-library', 'template']) {
      expect(
        () => StoreLock.parse(
          vendored(kind, 'libraries', 'just_x', 'packages/libraries/just_x'),
        ),
        throwsA(
          isA<StoreFormatException>().having(
            (e) => e.message,
            'message',
            contains('never copied into the project'),
          ),
        ),
        reason: kind,
      );
    }
    // A linked kit is someone's checkout, wherever it is.
    expect(
      StoreLock.parse(
        jsonEncode({
          'schema': 1,
          'items': {
            'just_platformer_kit': {
              'version': '0.1.0',
              'kind': 'kit',
              'origin': 'linked',
              'path': 'packages/just_platformer_kit',
            },
          },
        }),
      ).items['just_platformer_kit']!.path,
      'packages/just_platformer_kit',
    );
  });
}

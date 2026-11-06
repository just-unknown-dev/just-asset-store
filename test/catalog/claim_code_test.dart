// Claim codes, what just_release.json says about who may publish it, and
// the store page's fields a package's manifest carries.
import 'dart:convert';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

Map<String, Object?> manifestJson({
  String kind = 'kit',
  Map<String, Object?> extra = const {},
}) => {
  'schema': 1,
  'id': 'just_kit',
  'name': 'Just Kit',
  'version': '1.0.0',
  'kind': kind,
  'category': kind == 'content' ? 'characters' : 'kits',
  if (kind == 'content')
    'content': {
      'assetFolders': ['sprites/'],
    },
  ...extra,
};

void main() {
  group('claim codes', () {
    test('are the same for an account every time, and differ between '
        'accounts', () {
      expect(claimCode(583231), claimCode(583231));
      expect(claimCode(583231), isNot(claimCode(583232)));
      expect(isClaimCode(claimCode(1)), isTrue);
      expect(claimCode(1), hasLength('jas1-'.length + 16));
      expect(claimCode(1), startsWith('jas1-'));
    });

    test('are written one way only', () {
      for (final bad in [
        '',
        'jas1-',
        'jas1-ABCDEFGHIJKLMNOP',
        'jas1-abcdefghijklmno',
        'jas1-abcdefghijklmnop0',
        'jas2-abcdefghijklmnop',
        ' jas1-abcdefghijklmnop',
        'jas1-abcdefghijklmn01',
      ]) {
        expect(isClaimCode(bad), isFalse, reason: bad);
      }
      expect(isClaimCode('jas1-abcdefghijklmnop'), isTrue);
      expect(() => claimCode(0), throwsArgumentError);
    });
  });

  group('just_release.json', () {
    JustRelease release({String? claim}) => JustRelease(
      tag: 'v1.0.0',
      manifest: ItemManifest.fromJson(JsonFields(manifestJson())),
      version: {
        'version': '1.0.0',
        'archive': {'url': 'just_kit-1.0.0.zip', 'sha256': 'a' * 64, 'size': 1},
      },
      claim: claim,
    );

    test('carries its claim code', () {
      final code = claimCode(42);
      final text = release(claim: code).toText();
      expect(JustRelease.parse(text).claim, code);
      expect(JustRelease.parse(release().toText()).claim, isNull);
      expect(jsonDecode(release().toText()), isNot(contains('claim')));
    });

    test('refuses a claim that is not a code', () {
      final json = jsonDecode(release().toText()) as Map<String, Object?>;
      json['claim'] = 'my-account';
      expect(
        () => JustRelease.parse(jsonEncode(json)),
        throwsA(isA<JsonFormatException>()),
      );
    });
  });

  group('manifest fields for the store page', () {
    test('read and written back', () {
      final m = ItemManifest.fromJson(
        JsonFields(
          manifestJson(
            extra: {
              'summary': 'A kit.',
              'tags': ['platformer', 'kit'],
              'author': {'name': 'Ana', 'url': 'https://ana.example.com'},
              'permissions': ['network', 'native'],
            },
          ),
        ),
      );
      expect(m.summary, 'A kit.');
      expect(m.permissions, {ItemPermission.network, ItemPermission.native});
      final again = ItemManifest.fromJson(JsonFields(m.toJson()));
      expect(again.tags, m.tags);
      expect(again.author?.url, 'https://ana.example.com');
      expect(again.permissions, m.permissions);
      // Absent, they stay out of the file.
      final bare = ItemManifest.fromJson(JsonFields(manifestJson()));
      expect(bare.toJson(), isNot(contains('permissions')));
      expect(bare.toJson(), isNot(contains('summary')));
    });

    test('an unknown permission, and any for content, are refused', () {
      expect(
        () => ItemManifest.fromJson(
          JsonFields(
            manifestJson(
              extra: {
                'permissions': ['network', 'camera'],
              },
            ),
          ),
        ),
        throwsA(
          isA<JsonFormatException>().having(
            (e) => e.where,
            'where',
            'permissions[1]',
          ),
        ),
      );
      expect(
        () => ItemManifest.fromJson(
          JsonFields(
            manifestJson(
              kind: 'content',
              extra: {
                'permissions': ['network'],
              },
            ),
          ),
        ),
        throwsA(isA<JsonFormatException>()),
      );
    });

    test('pictures are image files inside the package, named apart', () {
      ItemManifest read(List<String> previews) => ItemManifest.fromJson(
        JsonFields(manifestJson(extra: {'previews': previews})),
      );
      expect(read(['store/card.png', 'store/shot-1.JPG']).previews, [
        'store/card.png',
        'store/shot-1.JPG',
      ]);
      for (final bad in [
        ['../card.png'], // outside the package
        ['/card.png'],
        ['store/'], // a folder
        ['store/notes.txt'], // not a picture
        ['store/card'],
        ['store/my card.png'], // GitHub would rename it
        ['a/card.png', 'b/CARD.png'], // the same release file
        [for (var i = 0; i < 9; i++) 'store/$i.png'], // too many
      ]) {
        expect(
          () => read(bad),
          throwsA(
            isA<JsonFormatException>().having(
              (e) => e.where,
              'where',
              'previews',
            ),
          ),
          reason: '$bad',
        );
      }
    });

    test('summary and tags are plain text', () {
      expect(
        () => ItemManifest.fromJson(
          JsonFields(manifestJson(extra: {'summary': 'Hi\u001b[8m'})),
        ),
        throwsA(isA<JsonFormatException>()),
      );
    });
  });
}

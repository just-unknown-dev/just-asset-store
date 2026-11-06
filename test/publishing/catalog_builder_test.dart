// Building a catalog from item folders.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';

void main() {
  group('CatalogBuilder', () {
    Directory repo({Map<String, String> extra = const {}}) {
      final dir = tempDir('repo');
      writeFiles(dir, {
        'catalog.json': jsonEncode({
          'source': {'id': 'just-official', 'name': 'Just Asset Store'},
          'categories': [
            {'id': 'characters', 'label': 'Characters', 'order': 10},
          ],
          'maintainers': ['just-maintainer'],
        }),
        'publishers/just.json': jsonEncode({
          'id': 'just',
          'name': 'Just',
          'github': ['ju-skb'],
          'trust': 'official',
        }),
        'publishers/pixel_folk.json': jsonEncode({
          'id': 'pixel_folk',
          'name': 'Pixel Folk',
          'github': ['pixelfolk'],
        }),
        'items/just_art_knight/item.json': jsonEncode({
          'id': 'just_art_knight',
          'name': 'Knight',
          'kind': 'content',
          'category': 'characters',
          'publisher': 'just',
          'trust': 'community',
        }),
        'items/just_art_knight/versions/1.0.0.json': jsonEncode({
          'version': '1.0.0',
          'archive': {
            'url': 'https://e.com/k-1.0.0.zip',
            'sha256': 'a' * 64,
            'size': 10,
          },
        }),
        'items/just_art_knight/versions/1.10.0.json': jsonEncode({
          'version': '1.10.0',
          'archive': {
            'url': 'https://e.com/k-1.10.0.zip',
            'sha256': 'b' * 64,
            'size': 10,
          },
        }),
        'items/just_art_knight/thumbnail.png': 'png',
        'items/just_art_knight/previews/1.png': 'png',
        'items/folk_trees/item.json': jsonEncode({
          'id': 'folk_trees',
          'name': 'Trees',
          'kind': 'content',
          'category': 'characters',
          'publisher': 'pixel_folk',
          'trust': 'official',
        }),
        'items/folk_trees/versions/0.1.0.json': jsonEncode({
          'version': '0.1.0',
          'archive': {
            'url': 'https://e.com/t.zip',
            'sha256': 'c' * 64,
            'size': 10,
          },
        }),
        ...extra,
      });
      return dir;
    }

    test('builds an index, trust from the publisher, versions in order', () {
      final build = CatalogBuilder.build(
        repo(),
        now: DateTime.utc(2026, 10, 7),
      );
      final knight = build.index.item('just_art_knight')!;
      expect(knight.trust, TrustLevel.official);
      expect(
        build.index.item('folk_trees')!.trust,
        TrustLevel.community,
        reason: 'an item cannot claim more',
      );
      expect(knight.versions.map((v) => '${v.version}'), ['1.0.0', '1.10.0']);
      expect(knight.thumbnail, 'items/just_art_knight/thumbnail.png');
      expect(knight.previews, ['items/just_art_knight/previews/1.png']);
      expect(
        build.assets.keys,
        containsAll([
          'items/just_art_knight/thumbnail.png',
          'items/just_art_knight/previews/1.png',
        ]),
      );
      expect(build.index.generatedAt, DateTime.utc(2026, 10, 7));
    });

    test('lists every problem, by item', () {
      try {
        CatalogBuilder.build(
          repo(
            extra: {
              'items/wrong_name/item.json': jsonEncode({
                'id': 'other',
                'name': 'X',
                'kind': 'content',
                'category': 'characters',
              }),
              'items/just_art_knight/versions/2.0.0.json': jsonEncode({
                'version': '2.0.1',
              }),
              'items/folk_trees/item.json': jsonEncode({
                'id': 'folk_trees',
                'name': 'Trees',
                'kind': 'content',
                'category': 'characters',
                'publisher': 'nobody',
              }),
            },
          ),
        );
        fail('should not build');
      } on CatalogBuildException catch (e) {
        final text = '$e';
        expect(
          text,
          contains('items/wrong_name/item.json: its "id" must be "wrong_name"'),
        );
        expect(
          text,
          contains('versions/2.0.0.json: its "version" must be "2.0.0"'),
        );
        expect(text, contains('publisher "nobody" has no file'));
      }
    });

    test('schema errors name the item, not its position', () {
      expect(
        () => CatalogBuilder.build(
          repo(
            extra: {
              'items/folk_trees/versions/0.1.0.json': jsonEncode({
                'version': '0.1.0',
                'archive': {
                  'url': 'https://e.com/t.zip',
                  'sha256': 'nope',
                  'size': 10,
                },
              }),
            },
          ),
        ),
        throwsA(
          isA<CatalogBuildException>().having(
            (e) => '$e',
            'text',
            contains('items/folk_trees.versions[0].archive.sha256'),
          ),
        ),
      );
    });

    test('CODEOWNERS gives each publisher its items', () {
      final text = CatalogBuilder.codeowners(repo());
      expect(text, contains('* @just-maintainer\n'));
      expect(
        text,
        contains('/items/folk_trees/ @pixelfolk @just-maintainer\n'),
      );
      expect(
        text,
        contains('/items/just_art_knight/ @ju-skb @just-maintainer\n'),
      );
      // A publisher's file says how far the store vouches for it: only the
      // maintainers approve changes to it, never the publisher.
      expect(text, contains('/publishers/ @just-maintainer\n'));
      expect(text, isNot(contains('/publishers/pixel_folk.json')));
    });
  });
}

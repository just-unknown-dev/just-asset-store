// Unlisted packages, straight from their GitHub releases.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/run_store.dart';
import '../support/temp_project.dart';
import '../support/test_catalog.dart';

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
  test('an unlisted install shows what the manifest says of it', () {
    final manifest = ItemManifest.fromJson(
      JsonFields(
        manifestJson(
          extra: {
            'summary': 'A kit.',
            'description': 'A kit\nfor platformers.',
            'tags': ['platformer'],
            'author': {'name': 'Ana'},
            'previews': ['store/card.png'],
          },
        ),
      ),
    );
    final item = GitHubSource.tryFrom('https://github.com/ana/just-kit')!
        .indexFor(
          JustRelease(
            tag: 'v1.0.0',
            manifest: manifest,
            version: {
              'version': '1.0.0',
              'archive': {
                'url': 'just_kit-1.0.0.zip',
                'sha256': 'a' * 64,
                'size': 1,
              },
            },
          ),
        )
        .items
        .single;
    expect(item.summary, 'A kit.');
    expect(item.description, 'A kit\nfor platformers.');
    expect(item.tags, ['platformer']);
    expect(item.author?.name, 'Ana');
    expect(item.trust, TrustLevel.community);
    // Pictures are the release's files, not paths inside the package.
    expect(item.previews, [
      'https://github.com/ana/just-kit/releases/download/v1.0.0/card.png',
    ]);
  });

  group('unlisted packages from GitHub', () {
    test('a URL names the repository and, after @, the release', () {
      final latest = GitHubSource.tryFrom(
        'https://github.com/studio/fancy-kit',
      )!;
      expect('${latest.repo}', 'studio/fancy-kit');
      expect(
        '${latest.indexUri}',
        'https://github.com/studio/fancy-kit/releases/latest/download/just_release.json',
      );
      final tagged = GitHubSource.tryFrom(
        'github.com/studio/fancy-kit@v1.2.0',
      )!;
      expect(tagged.tag, 'v1.2.0');
      final again = GitHubSource.tryFrom('${tagged.indexUri}')!;
      expect(again.tag, 'v1.2.0');
      expect(GitHubSource.tryFrom('https://example.com/a/b'), isNull);
      expect(GitHubSource.tryFrom('just_art_knight'), isNull);
    });

    test('a release becomes one community item pinned to its tag', () {
      final manifest = ItemManifest.parse(
        jsonEncode({
          'schema': 1,
          'id': 'fancy_kit',
          'name': 'Fancy Kit',
          'version': '1.2.0',
          'kind': 'kit',
          'category': 'kits',
        }),
      );
      final release = JustRelease.parse(
        JustRelease(
          tag: 'v1.2.0',
          manifest: manifest,
          version: {
            'version': '1.2.0',
            'archive': {
              'url': 'fancy_kit-1.2.0.zip',
              'sha256': 'a' * 64,
              'size': 10,
            },
          },
        ).toText(),
      );
      final index = GitHubSource.tryFrom(
        'https://github.com/studio/fancy-kit',
      )!.indexFor(release);
      final item = index.items.single;
      expect(item.trust, TrustLevel.community);
      expect(index.source.id, 'github:studio/fancy-kit');
      expect(
        item.versions.single.archive!.url,
        'https://github.com/studio/fancy-kit/releases/download/v1.2.0/fancy_kit-1.2.0.zip',
        reason: 'never latest/download: the lockfile must restore these bytes',
      );
    });

    test('pack writes the release file beside the archive', () async {
      final pkg = tempDir('pkg');
      packageFiles(TestItem('just_art_knight'), '1.0.0').forEach((path, bytes) {
        File('${pkg.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      });
      final outDir = tempDir('dist');
      final (code, _, err) = await store(['pack', pkg.path, '-o', outDir.path]);
      expect(code, 0, reason: err);
      final release = JustRelease.parse(
        File('${outDir.path}/just_release.json').readAsStringSync(),
      );
      expect(release.tag, 'v1.0.0');
      expect(release.manifest.id, 'just_art_knight');
      expect(
        (release.version['archive'] as Map)['url'],
        'just_art_knight-1.0.0.zip',
      );
    });
  });
}

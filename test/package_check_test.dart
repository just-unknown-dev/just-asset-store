// What a downloaded package must look like to be installed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/test_items.dart';

StoreItem catalogItem(TestItem t, {TrustLevel trust = TrustLevel.official}) =>
    StoreItem(
      trust: trust,
      id: t.id,
      name: t.id,
      kind: t.kind,
      category: t.category,
      versions: [
        StoreItemVersion(
          version: Version.parse(t.versions.first),
          archive: const StoreArchive(url: 'a.zip', sha256: '', size: 1),
        ),
      ],
    );

CheckedPackage check(
  TestItem t, {
  void Function(Map<String, List<int>> files)? change,
  String? wrapIn,
  TrustLevel trust = TrustLevel.official,
  Set<String> executable = const {},
}) {
  final files = packageFiles(t, t.versions.first);
  change?.call(files);
  final zip = ZipWriter();
  files.forEach(
    (k, v) => zip.add(
      wrapIn == null ? k : '$wrapIn/$k',
      v,
      executable: executable.contains(k),
    ),
  );
  final item = catalogItem(t, trust: trust);
  return PackageCheck.check(
    ZipArchive.read(zip.close()),
    item,
    item.versions.single,
  );
}

Matcher refused(String containing) => throwsA(
  isA<PackageCheckException>().having(
    (e) => e.problems.join('\n'),
    'problems',
    contains(containing),
  ),
);

void main() {
  final knight = TestItem('just_art_knight');
  final kit = TestItem(
    'just_kit',
    kind: ItemKind.kit,
    category: 'kits',
    modules: ['KitModule'],
    files: {'lib/editor.dart': 'class KitModule {}', 'lib/just_kit.dart': ''},
  );

  test('a good content item', () {
    final p = check(knight);
    expect(p.manifest.id, 'just_art_knight');
    expect(
      p.files.keys,
      containsAll([
        'pubspec.yaml',
        'just_store.json',
        'sprites/just_art_knight.png',
      ]),
    );
    expect(p.size, greaterThan(0));
  });

  test('a good kit, with Dart code', () {
    expect(check(kit).manifest.modules.single.className, 'KitModule');
  });

  test('a single top folder (GitHub source archives) is unwrapped', () {
    expect(
      check(knight, wrapIn: 'just_art_knight-1.0.0').files,
      contains('pubspec.yaml'),
    );
  });

  test('the files the archive marks executable are named, unwrapped too', () {
    expect(check(kit).executable, isEmpty);
    expect(check(kit, executable: {'lib/editor.dart'}).executable, {
      'lib/editor.dart',
    });
    expect(
      check(
        kit,
        executable: {'lib/editor.dart'},
        wrapIn: 'just_kit-1.0.0',
      ).executable,
      {'lib/editor.dart'},
    );
  });

  test('manifest and pubspec must match the catalog', () {
    expect(
      () => check(
        knight,
        change: (f) =>
            f['pubspec.yaml'] = utf8.encode('name: other\nversion: 1.0.0\n'),
      ),
      refused('names "other"'),
    );
    expect(
      () => check(
        knight,
        change: (f) {
          final m = jsonDecode(utf8.decode(f['just_store.json']!)) as Map;
          m['version'] = '9.9.9';
          f['just_store.json'] = utf8.encode(jsonEncode(m));
        },
      ),
      refused('version 9.9.9'),
    );
    expect(
      () => check(knight, change: (f) => f.remove('just_store.json')),
      refused('no just_store.json'),
    );
  });

  test('content holds no code and no unknown file types', () {
    expect(
      () => check(knight, change: (f) => f['sprites/x.dart'] = [1]),
      refused('.dart file'),
    );
    expect(
      () => check(knight, change: (f) => f['sprites/run.exe'] = [1]),
      refused('.exe'),
    );
    expect(
      () => check(kit, change: (f) => f['lib/x.so'] = [1]),
      refused('.so'),
    );
  });

  test('no build hooks, platform folders, hidden files or lockfiles', () {
    for (final e in {
      'hook/build.dart': 'hook/',
      'windows/runner.cpp': 'windows/',
      '.github/x.yaml': 'hidden',
      'lib/.secret.json': 'hidden',
      'pubspec.lock': 'must not',
    }.entries) {
      expect(
        () => check(kit, change: (f) => f[e.key] = [1]),
        refused(e.value),
        reason: e.key,
      );
    }
  });

  test('no path, git or other-server dependencies, however written', () {
    CheckedPackage withDependencies(
      TestItem item,
      String dependencies,
    ) => check(
      item,
      change: (f) => f['pubspec.yaml'] = utf8.encode(
        'name: ${item.id}\nversion: 1.0.0\ndependencies:\n$dependencies'
        '${item.kind == ItemKind.content ? 'flutter:\n  assets:\n    - sprites/\n' : ''}',
      ),
    );
    for (final entry in [
      '  evil:\n    path: ../../evil\n',
      '  evil:\n    git: https://e.com/e.git\n',
      // A quoted key is the same key to pub.
      '  evil: {"git": "https://e.com/e.git"}\n',
      "  evil:\n    'path': ../../evil\n",
      // Another package server.
      '  evil:\n    hosted: https://pub.example.com\n    version: ^1.0.0\n',
      '  evil:\n    git:\n      url: https://e.com/e.git\n      ref: main\n',
    ]) {
      expect(
        () => withDependencies(kit, entry),
        refused('by path, git or another package server'),
        reason: entry,
      );
    }
    // A comment that looks like an SDK dependency is still a comment.
    expect(
      () => withDependencies(
        knight,
        '  evil: {"git": "https://e.com/e.git"} # sdk: flutter\n',
      ),
      refused('A content item depends on nothing'),
    );
    // What pub.dev and the SDK give is allowed.
    expect(
      withDependencies(
        kit,
        '  flutter:\n    sdk: flutter # the SDK\n'
        '  meta: ^1.0.0\n'
        '  collection:\n    hosted: https://pub.dev\n    version: ^1.0.0\n',
      ).manifest.id,
      'just_kit',
    );
    expect(
      withDependencies(knight, '  flutter: {sdk: flutter}\n').manifest.id,
      'just_art_knight',
    );
  });

  test('build hooks and platform folders, whatever their case', () {
    for (final path in ['Hook/build.dart', 'HOOK/build.dart', 'Windows/x.cc']) {
      expect(
        () => check(kit, change: (f) => f[path] = [1]),
        refused('which store packages may not have'),
        reason: path,
      );
    }
  });

  test('every library the manifest registers is in the package', () {
    expect(
      () => check(kit, change: (f) => f.remove('lib/editor.dart')),
      refused('it has no lib/editor.dart'),
    );
  });

  test('a pubspec is read in time linear in its length', () {
    final watch = Stopwatch()..start();
    expect(
      () => check(
        kit,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: a${' ' * 40000}b\nversion: 1.0.0\n',
        ),
      ),
      refused('a line longer than 1000 characters'),
    );
    expect(
      () => check(
        kit,
        change: (f) => f['pubspec.yaml'] = List.filled(
          PackageCheck.maxPubspecBytes + 1,
          0x20,
        ),
      ),
      refused('larger than 64 KiB'),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('content files must sit directly in a listed asset folder', () {
    expect(
      () => check(knight, change: (f) => f['sprites/deep/x.png'] = [1]),
      refused('would not ship'),
    );
    expect(
      () => check(
        knight,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: just_art_knight\nversion: 1.0.0\nflutter:\n  assets:\n    - sprites/\n    - extra/\n',
        ),
      ),
      refused('"extra/"'),
    );
  });

  test('content depends on nothing and is not a plugin', () {
    expect(
      () => check(
        knight,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: just_art_knight\nversion: 1.0.0\ndependencies:\n  http: ^1.0.0\n'
          'flutter:\n  assets:\n    - sprites/\n',
        ),
      ),
      refused('depends on nothing'),
    );
    // The Flutter SDK itself is fine.
    expect(
      check(
        knight,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: just_art_knight\nversion: 1.0.0\ndependencies:\n  flutter:\n    sdk: flutter\n'
          'flutter:\n  assets:\n    - sprites/\n',
        ),
      ).manifest.id,
      'just_art_knight',
    );
  });

  test('PubspecFacts reads assets in both styles', () {
    final facts = PubspecFacts.parse(
      "name: x\nversion: '1.0.0'\nflutter:\n  uses-material-design: true\n"
      '  assets:\n    - a/\n    - "b/"\n    - path: c/\n      flavors: [dev]\n'
      '  plugin:\n    platforms: {}\n',
    );
    expect(facts.name, 'x');
    expect(facts.version, '1.0.0');
    expect(facts.assets, ['a/', 'b/', 'c/']);
    expect(facts.hasPlugin, isTrue);
  });

  test('every problem is listed at once', () {
    try {
      check(
        knight,
        change: (f) => f
          ..['sprites/a.dart'] = [1]
          ..['hook/b.dart'] = Uint8List(1),
      );
      fail('should refuse');
    } on PackageCheckException catch (e) {
      expect(e.problems.length, greaterThanOrEqualTo(2));
      expect('$e', contains('cannot be installed'));
    }
  });

  test('bin/ is for official tools only', () {
    expect(
      check(kit, change: (f) => f['bin/tool.dart'] = [1]).files,
      contains('bin/tool.dart'),
    );
    expect(
      () => check(
        kit,
        trust: TrustLevel.community,
        change: (f) => f['bin/tool.dart'] = [1],
      ),
      refused('bin/'),
    );
  });
}

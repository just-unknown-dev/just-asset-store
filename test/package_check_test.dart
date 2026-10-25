// What a downloaded package must look like to be installed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/test_items.dart';

StoreItem catalogItem(
  TestItem t, {
  TrustLevel trust = TrustLevel.official,
  Set<ItemPermission>? listed,
}) => StoreItem(
      trust: trust,
      id: t.id,
      name: t.id,
      kind: t.kind,
      category: t.category,
      versions: [
        StoreItemVersion(
          version: Version.parse(t.versions.first),
          archive: const StoreArchive(url: 'a.zip', sha256: '', size: 1),
          pubDependencies: {
            for (final e in t.pubDependencies.entries)
              e.key: VersionConstraint.parse(e.value),
          },
          nativePlugins: t.nativePlugins,
          permissions:
              listed ??
              {for (final p in t.permissions) ItemPermission.byId[p]!},
          stage: t.stage == null ? null : ItemStage.byId[t.stage!],
          replacedBy: t.replacedBy,
        ),
      ],
    );

CheckedPackage check(
  TestItem t, {
  void Function(Map<String, List<int>> files)? change,
  String? wrapIn,
  TrustLevel trust = TrustLevel.official,
  Set<String> executable = const {},
  Set<ItemPermission>? listed,
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
  final item = catalogItem(t, trust: trust, listed: listed);
  final bytes = zip.close();
  // Every case is also checked as the store's backend checks an archive on
  // a server before downloading it: the directory read from its end, and
  // only the two small files the rules read. The verdict must be the same.
  final dir = ZipDirectory.fromTail(bytes, totalLength: bytes.length);
  Object quick;
  try {
    quick = PackageCheck.checkLayout(
      PackageCheck.layoutFromEntries(
        dir.files,
        (e) => dir.contentFrom(e, bytes, start: 0),
      ),
      item,
      item.versions.single,
    );
  } on PackageCheckException catch (e) {
    quick = e;
  }
  try {
    final checked = PackageCheck.check(
      ZipArchive.read(bytes),
      item,
      item.versions.single,
    );
    expect(quick, isA<PackageFacts>(), reason: 'the quick look refused it');
    final facts = quick as PackageFacts;
    expect(facts.manifest.id, checked.manifest.id);
    expect(facts.notes, checked.notes);
    expect(facts.dependencies, checked.dependencies);
    return checked;
  } on PackageCheckException catch (e) {
    expect(
      quick,
      isA<PackageCheckException>().having(
        (q) => q.problems,
        'problems',
        e.problems,
      ),
      reason: 'the quick look must refuse it for the same reasons',
    );
    rethrow;
  }
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
    // What pub.dev and the SDK give is allowed, when the catalog says so.
    final kitWithPub = TestItem(
      'just_kit',
      kind: ItemKind.kit,
      category: 'kits',
      modules: ['KitModule'],
      files: {'lib/editor.dart': 'class KitModule {}', 'lib/just_kit.dart': ''},
      pubDependencies: {'meta': '^1.0.0', 'collection': '^1.0.0'},
    );
    expect(
      withDependencies(
        kitWithPub,
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

  test('a key spelled with YAML escapes is the key pub reads', () {
    // Each hid a git dependency from the old line-by-line reader, while pub
    // read it (the 2026-10-23 review's probe).
    for (final pubspec in [
      'name: just_kit\nversion: 1.0.0\n'
          '"dependencie\\x73":\n  evil:\n    git: https://e.com/e.git\n',
      'name: just_kit\nversion: 1.0.0\n'
          '? dependencies\n: evil:\n    git: https://e.com/e.git\n',
      'name: just_kit\nversion: 1.0.0\ndependencies:\n'
          '  "evil\\x5fdep":\n    path: C:/Users/Public/evil\n',
    ]) {
      expect(
        () => check(
          kit,
          change: (f) => f['pubspec.yaml'] = utf8.encode(pubspec),
        ),
        refused('never by path, git or another package server'),
        reason: pubspec,
      );
    }
    // A key written twice is refused, as pub refuses it.
    expect(
      () => check(
        kit,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: just_kit\nversion: 1.0.0\ndependencies: {}\n'
          '"dependencie\\x73": {}\n',
        ),
      ),
      refused('pubspec.yaml'),
    );
    // So is a field pub doesn't document, or one a store package has no
    // use for.
    for (final field in ['made_up: 1', 'resolution: workspace']) {
      expect(
        () => check(
          kit,
          change: (f) => f['pubspec.yaml'] = utf8.encode(
            'name: just_kit\nversion: 1.0.0\n$field\n',
          ),
        ),
        refused('a field the store does not read'),
        reason: field,
      );
    }
    // Build hook settings for its own tests are fine (pub reads them from
    // the project alone); nothing else goes under hooks:.
    expect(
      PubspecFacts.parse(
        'name: just_kit\nhooks:\n  user_defines:\n    just_jolt:\n'
        '      build: true\n',
      ).name,
      'just_kit',
    );
    expect(
      () => PubspecFacts.parse('name: just_kit\nhooks:\n  build: {}\n'),
      throwsA(isA<PubspecFormatException>()),
    );
  });

  test('the packages it brings from pub.dev are the ones the catalog shows', () {
    expect(
      () => check(
        kit,
        change: (f) => f['pubspec.yaml'] = utf8.encode(
          'name: just_kit\nversion: 1.0.0\ndependencies:\n  http: ^1.0.0\n',
        ),
      ),
      refused('disagree on the packages it needs from pub.dev (http)'),
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

  test('what it may do is what the catalog shows', () {
    final tool = TestItem(
      'their_tool',
      kind: ItemKind.editorExtension,
      category: 'editors',
      permissions: ['network'],
    );
    expect(check(tool).manifest.permissions, {ItemPermission.network});
    expect(
      () => check(tool, listed: const {}),
      refused(
        'Its manifest and the catalog disagree on what it may do: network '
        'against nothing. The store shows users what the catalog says.',
      ),
    );
  });

  test('native code is declared', () {
    final tool = TestItem(
      'their_tool',
      kind: ItemKind.editorExtension,
      category: 'editors',
      nativePlugins: ['file_selector'],
      permissions: [],
    );
    expect(
      () => check(tool),
      refused(
        'It brings native code (file_selector), but its just_store.json '
        'does not list "native" in its permissions.',
      ),
    );
    // A plugin itself is native code too.
    final plugin = TestItem(
      'their_plugin',
      kind: ItemKind.editorExtension,
      category: 'editors',
    );
    expect(
      () => check(
        plugin,
        change: (f) => f['pubspec.yaml'] = [
          ...f['pubspec.yaml']!,
          ...utf8.encode('flutter:\n  plugin:\n    platforms: {}\n'),
        ],
      ),
      refused('It brings native code (their_plugin), but'),
    );
    expect(
      check(
        TestItem(
          'their_tool',
          kind: ItemKind.editorExtension,
          category: 'editors',
          nativePlugins: ['file_selector'],
        ),
      ).manifest.permissions,
      {ItemPermission.native},
    );
  });

  test('every plugin names its stage, as the catalog does', () {
    final tool = TestItem(
      'their_tool',
      kind: ItemKind.editorExtension,
      category: 'editors',
      stage: 'experimental',
    );
    expect(check(tool).manifest.stage, ItemStage.experimental);
    expect(
      () => check(
        tool,
        change: (f) {
          final m = jsonDecode(utf8.decode(f['just_store.json']!)) as Map;
          m.remove('stage');
          f['just_store.json'] = utf8.encode(jsonEncode(m));
        },
      ),
      refused('names no "stage": "stable", "beta", "experimental" or'),
    );
    final kit = TestItem('their_kit', kind: ItemKind.kit, category: 'kits');
    expect(
      () => check(
        kit,
        change: (f) {
          final m = jsonDecode(utf8.decode(f['just_store.json']!)) as Map;
          m['stage'] = 'stable';
          f['just_store.json'] = utf8.encode(jsonEncode(m));
        },
      ),
      refused('disagree on its stage: stable against beta'),
    );
    // Content names none, and needs none.
    expect(check(TestItem('just_art_knight')).manifest.stage, isNull);
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

  group('checking an archive before downloading it', () {
    // A large content item: what the quick look reads must stay small.
    Uint8List bigKnight({void Function(Map<String, List<int>>)? change}) {
      final files = packageFiles(knight, knight.versions.first);
      // Noise, so it doesn't pack small.
      var seed = 7;
      for (var i = 0; i < 40; i++) {
        files['sprites/frame_$i.png'] = [
          for (var b = 0; b < 50000; b++)
            (seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF) >> 16 & 0xFF,
        ];
      }
      change?.call(files);
      final zip = ZipWriter();
      files.forEach(zip.add);
      return zip.close();
    }

    Future<(Object, int)> quickLook(Uint8List bytes) async {
      var read = 0;
      Future<Uint8List> ranges(int start, int end) async {
        read += end - start;
        return Uint8List.sublistView(bytes, start, end);
      }

      final item = catalogItem(knight);
      try {
        final dir = await ZipDirectory.fetch(ranges, bytes.length);
        final layout = await PackageCheck.layoutOf(dir, ranges);
        return (
          PackageCheck.checkLayout(layout, item, item.versions.single)
              as Object,
          read,
        );
      } on PackageCheckException catch (e) {
        return (e as Object, read);
      }
    }

    test('passes a good package, reading a sliver of it', () async {
      final bytes = bigKnight();
      final (verdict, read) = await quickLook(bytes);
      expect(verdict, isA<PackageFacts>());
      expect(bytes.length, greaterThan(1000000));
      expect(read, lessThan(ZipDirectory.tailBytes + 16 * 1024));
    });

    test('refuses a bad one the same way, still before downloading',
        () async {
      final bytes = bigKnight(change: (f) => f['hook/build.dart'] = [1]);
      final (verdict, read) = await quickLook(bytes);
      expect(
        verdict,
        isA<PackageCheckException>().having(
          (e) => e.problems.join('\n'),
          'problems',
          contains('hook/'),
        ),
      );
      expect(read, lessThan(bytes.length ~/ 4));
    });

    test('verify unpacks and checks every file without keeping one', () {
      final good = bigKnight();
      final item = catalogItem(knight);
      final facts = PackageCheck.verify(
        ZipArchive.read(good),
        item,
        item.versions.single,
      );
      expect(facts.manifest.id, 'just_art_knight');
      // A file damaged on the way passes the rules, but not verify.
      final frame = ZipArchive.read(good).entry('sprites/frame_3.png')!;
      final damaged = Uint8List.fromList(good);
      damaged[_dataStart(good, frame) + 100] ^= 0xFF;
      expect(
        PackageCheck.checkLayout(
          PackageCheck.layoutFromEntries(
            ZipArchive.read(damaged).files,
            ZipArchive.read(damaged).contentOf,
          ),
          item,
          item.versions.single,
        ).manifest.id,
        'just_art_knight',
      );
      expect(
        () => PackageCheck.verify(
          ZipArchive.read(damaged),
          item,
          item.versions.single,
        ),
        throwsA(isA<ZipFormatException>()),
      );
    });
  });
}

/// Where [entry]'s data starts in [bytes]: after its local header.
int _dataStart(Uint8List bytes, ZipEntry entry) {
  final name = utf8.encode(entry.path);
  for (var i = 0; i + 30 + name.length < bytes.length; i++) {
    if (bytes[i] != 0x50 || bytes[i + 1] != 0x4b) continue;
    if (bytes[i + 2] != 3 || bytes[i + 3] != 4) continue;
    final nameLength = bytes[i + 26] | (bytes[i + 27] << 8);
    final extraLength = bytes[i + 28] | (bytes[i + 29] << 8);
    if (nameLength != name.length) continue;
    var same = true;
    for (var k = 0; k < name.length; k++) {
      if (bytes[i + 30 + k] != name[k]) {
        same = false;
        break;
      }
    }
    if (same) return i + 30 + nameLength + extraLength;
  }
  throw StateError('No local header for ${entry.path}.');
}

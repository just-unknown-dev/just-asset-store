// Linking a developer's checkout, and vendoring it into the project as an
// ordinary installed item.
import 'dart:convert';
import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import 'support/temp_project.dart';
import 'support/test_catalog.dart';

Directory project({String extra = ''}) {
  final dir = tempDir('linker');
  writeFiles(dir, {
    'pubspec.yaml': pubspecOf(
      'app',
      extra: 'dependencies:\n  just_tool: ^1.0.0\n$extra',
    ),
    // A developer's checkout of a store item, with what a checkout has.
    'dev/just_tool/pubspec.yaml': pubspecOf('just_tool', version: '1.2.0'),
    'dev/just_tool/just_store.json': jsonEncode({
      'schema': 1,
      'id': 'just_tool',
      'name': 'Tool',
      'version': '1.2.0',
      'kind': 'editor-extension',
      'category': 'editors',
      'editor': {
        'modules': [
          {'library': 'package:just_tool/editor.dart', 'class': 'ToolModule'},
        ],
        'editorOnlyLibraries': ['*'],
      },
    }),
    'dev/just_tool/lib/editor.dart': 'class ToolModule {}\n',
    'dev/just_tool/bin/tool.dart': 'void main() {}\n',
    'dev/just_tool/test/tool_test.dart': '',
    'dev/just_tool/.dart_tool/package_config.json': '{}',
  });
  return dir;
}

void main() {
  test('link records a checkout and registers it; unlink forgets it', () {
    final dir = project();
    final p = StoreProject(dir.path);
    expect(StoreLinker.link(p, ['dev/just_tool']), ['just_tool']);
    final item = p.readLock().items['just_tool']!;
    expect(item.origin, ItemOrigin.linked);
    expect(item.path, 'dev/just_tool');
    expect(item.version, '1.2.0');
    expect(
      p.file(StoreProject.modulesFile).readAsStringSync(),
      contains('s0.ToolModule()'),
    );
    expect(StoreRegistry.outdated(p), isEmpty);

    expect(StoreLinker.unlink(p, 'just_tool'), isTrue);
    expect(p.readLock().items, isEmpty);
    expect(
      p.file(StoreProject.modulesFile).readAsStringSync(),
      contains('storeModules() => [];'),
    );
    expect(StoreLinker.unlink(p, 'just_tool'), isFalse);
    expect(Directory('${dir.path}/dev/just_tool').existsSync(), isTrue);
  });

  test('link refuses a folder without a manifest', () {
    final dir = project();
    writeFiles(dir, {'dev/plain/pubspec.yaml': pubspecOf('plain')});
    expect(
      () => StoreLinker.link(StoreProject(dir.path), ['dev/plain']),
      throwsA(isA<StoreFormatException>()),
    );
  });

  test('vendor copies a linked item in, as an installed item', () async {
    final dir = project();
    final p = StoreProject(dir.path);
    StoreLinker.link(p, ['dev/just_tool']);
    final pub = FakePub();
    final result = await StoreLinker.vendor(p, ['just_tool'], pub: pub);

    expect(result.changes.single.path, 'packages/editors/just_tool');
    expect(
      File(
        '${dir.path}/packages/editors/just_tool/lib/editor.dart',
      ).existsSync(),
      isTrue,
    );
    expect(
      File('${dir.path}/packages/editors/just_tool/bin/tool.dart').existsSync(),
      isTrue,
      reason: 'official tools may',
    );
    expect(
      Directory('${dir.path}/packages/editors/just_tool/test').existsSync(),
      isFalse,
    );
    expect(
      Directory(
        '${dir.path}/packages/editors/just_tool/.dart_tool',
      ).existsSync(),
      isFalse,
    );
    expect(
      Directory('${dir.path}/dev/just_tool').existsSync(),
      isTrue,
      reason: 'the checkout stays',
    );

    final pubspec = PubspecEditor.parse(
      p.file('pubspec.yaml').readAsStringSync(),
      marker: storeBlock,
    );
    expect(
      pubspec.unmanaged('dependencies'),
      isNot(contains('just_tool')),
      reason: 'taken over',
    );
    expect(pubspec.managed('dev_dependencies'), {
      'just_tool': const PathDependency('packages/editors/just_tool'),
    });
    expect(pubspec.managed('dependency_overrides').keys, ['just_tool']);

    final item = p.readLock().items['just_tool']!;
    expect(item.origin, ItemOrigin.vendored);
    expect(item.archive, isNull);
    expect(item.source, isNull);
    expect(
      item.files.keys,
      containsAll(['pubspec.yaml', 'just_store.json', 'lib/editor.dart']),
    );
    expect(p.readLock().sources, isEmpty);
    expect(pub.calls, ['get']);
    expect(StoreRegistry.outdated(p), isEmpty);
  });

  test("vendor is refused while the overrides point at the checkout", () async {
    final dir = project();
    writeFiles(dir, {
      'pubspec_overrides.yaml':
          'dependency_overrides:\n  just_tool:\n    path: dev/just_tool\n',
    });
    final p = StoreProject(dir.path);
    StoreLinker.link(p, ['dev/just_tool']);
    final before = snapshot(dir);
    await expectLater(
      StoreLinker.vendor(p, ['just_tool'], pub: FakePub()),
      throwsA(
        isA<InstallFailure>().having(
          (e) => e.message,
          'message',
          contains('clean copy'),
        ),
      ),
    );
    expect(snapshot(dir).keys.toSet(), before.keys.toSet());
    await expectLater(
      StoreLinker.vendor(p, ['nope'], pub: FakePub()),
      throwsA(
        isA<InstallFailure>().having(
          (e) => e.message,
          'message',
          contains('not a linked item'),
        ),
      ),
    );
  });
}

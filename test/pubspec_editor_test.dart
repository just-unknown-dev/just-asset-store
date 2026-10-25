// The pubspec editor: the store's blocks change, every other byte stays,
// and anything it can't edit safely is refused.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const knight = PathDependency('packages/characters/just_art_knight');
const sprites = PathDependency('plugins/editors/just_sprite_editor');

void main() {
  // A copy of the template's own files: pubspec.yaml has CRLF endings and
  // long comments; pubspec_overrides.yaml has LF and a melos header.
  final pubspec = fixture('template_pubspec.yaml');
  final overrides = fixture('template_overrides.yaml');

  group('reading', () {
    test('unchanged text round-trips byte for byte', () {
      for (final text in [
        pubspec,
        overrides,
        '',
        'name: x',
        'name: x\n\n\n',
        '\uFEFFname: x\r\ndependencies:\r\n  a: ^1.0.0\r\n',
        'name: x\r\nmixed: 1\nendings: 2\r\n',
      ]) {
        expect(PubspecEditor.parse(text, marker: storeBlock).text, text);
      }
    });

    test('keeps the file\'s line ending', () {
      expect(
        PubspecEditor.parse(pubspec, marker: storeBlock).lineEnding,
        '\r\n',
      );
      expect(
        PubspecEditor.parse(overrides, marker: storeBlock).lineEnding,
        '\n',
      );
    });

    test('lists the entries of a section', () {
      final deps = PubspecEditor.parse(
        pubspec,
        marker: storeBlock,
      ).unmanaged('dependencies');
      expect(deps['just_game_engine'], const HostedDependency('^2.0.0'));
      expect(deps['cupertino_icons'], const HostedDependency('^1.0.8'));
      expect(deps['flutter'], isA<OtherDependency>(), reason: 'sdk: flutter');
      expect(deps.keys, contains('just_input_editor'));
      final dev = PubspecEditor.parse(
        pubspec,
        marker: storeBlock,
      ).unmanaged('dev_dependencies');
      expect(dev.keys.toSet(), {'flutter_test', 'flutter_lints'});
    });

    test('reads path overrides and the melos header', () {
      final editor = PubspecEditor.parse(overrides, marker: storeBlock);
      final o = editor.unmanaged('dependency_overrides');
      expect(
        o['just_sprite_editor'],
        const PathDependency('packages/just_sprite_editor'),
      );
      expect(editor.melosManaged, {
        'dart_mappable_builder',
        'digit_data_model',
      });
    });

    test('flow paths, quoted constraints, hosted urls and comments', () {
      final deps = PubspecEditor.parse(
        'dependencies:\n'
        '  a: {path: ../a}\n'
        "  b: '>=1.0.0 <2.0.0' # why\n"
        '  c:\n'
        '    hosted: https://pub.example.com\n'
        '    version: ^1.0.0\n'
        '  d:\n'
        '    git: https://example.com/d.git\n',
        marker: storeBlock,
      ).unmanaged('dependencies');
      expect(deps['a'], const PathDependency('../a'));
      expect(deps['b'], const HostedDependency('>=1.0.0 <2.0.0'));
      expect(
        deps['c'],
        const HostedDependency('^1.0.0', url: 'https://pub.example.com'),
      );
      expect(deps['d'], isA<OtherDependency>());
    });
  });

  group('writing a block', () {
    test('into a new section, at the end, with the file\'s CRLF', () {
      final editor = PubspecEditor.parse(pubspec, marker: storeBlock)
        ..setManaged('dependency_overrides', {'just_art_knight': knight});
      final text = editor.text;
      expect(
        text.startsWith(pubspec),
        isTrue,
        reason: 'nothing before changes',
      );
      expect(
        text.substring(pubspec.length),
        '\r\ndependency_overrides:\r\n'
        '  ${storeBlock.start}\r\n'
        '  just_art_knight:\r\n'
        '    path: packages/characters/just_art_knight\r\n'
        '  ${storeBlock.end}\r\n',
      );
      expect(
        PubspecEditor.parse(
          text,
          marker: storeBlock,
        ).managed('dependency_overrides'),
        {'just_art_knight': knight},
      );
    });

    test('into an existing section, after its last entry', () {
      final editor = PubspecEditor.parse(pubspec, marker: storeBlock)
        ..setManaged('dev_dependencies', {'just_sprite_editor': sprites});
      final lines = editor.text.split('\r\n');
      final lints = lines.indexOf('  flutter_lints: ^6.0.0');
      expect(lines[lints + 1], '  ${storeBlock.start}');
      expect(lines[lints + 4], '  ${storeBlock.end}');
      expect(
        lines[lints + 5],
        '',
        reason: 'the blank line before the comments',
      );
      expect(lines[lints + 6], startsWith('# For information'));
    });

    test('replaces the block, sorted by name', () {
      final editor = PubspecEditor.parse(pubspec, marker: storeBlock)
        ..setManaged('dev_dependencies', {'just_sprite_editor': sprites})
        ..setManaged('dev_dependencies', {
          'zeta': const HostedDependency('^1.0.0'),
          'just_sprite_editor': sprites,
          'alpha': const HostedDependency('>=1.0.0 <2.0.0'),
        });
      final again = PubspecEditor.parse(editor.text, marker: storeBlock);
      expect(again.managed('dev_dependencies').keys.toList(), [
        'alpha',
        'just_sprite_editor',
        'zeta',
      ]);
      expect(editor.text, contains("  alpha: '>=1.0.0 <2.0.0'\r\n"));
      expect(again.unmanaged('dev_dependencies').keys.toSet(), {
        'flutter_test',
        'flutter_lints',
      });
    });

    test('adding then removing gives back the original bytes', () {
      for (final section in [
        'dependency_overrides',
        'dev_dependencies',
        'dependencies',
      ]) {
        final editor = PubspecEditor.parse(pubspec, marker: storeBlock)
          ..setManaged(section, {'just_art_knight': knight})
          ..setManaged(section, const {});
        expect(editor.text, pubspec, reason: section);
      }
      final o = PubspecEditor.parse(overrides, marker: storeBlock)
        ..setManaged('dependency_overrides', {'just_art_knight': knight})
        ..setManaged('dependency_overrides', const {});
      expect(o.text, overrides);
    });

    test('an empty section the store made is removed with its block', () {
      final editor = PubspecEditor.parse('name: x\n', marker: storeBlock)
        ..setManaged('dependency_overrides', {'a': knight});
      expect(editor.text, contains('dependency_overrides:'));
      editor.setManaged('dependency_overrides', const {});
      expect(editor.text, 'name: x\n');
    });

    test('keeps a byte order mark and a missing final newline', () {
      final editor = PubspecEditor.parse('\uFEFFname: x', marker: storeBlock)
        ..setManaged('dependencies', {'a': knight});
      expect(editor.text, startsWith('\uFEFFname: x\n\ndependencies:\n'));
      expect(editor.text.endsWith('\n'), isFalse);
    });
  });

  group('lines the store does not own', () {
    test('an identical entry outside the block is adopted', () {
      final editor = PubspecEditor.parse(overrides, marker: storeBlock)
        ..setManaged('dependency_overrides', {
          'just_sprite_editor': const PathDependency(
            'packages/just_sprite_editor/',
          ),
        });
      final again = PubspecEditor.parse(editor.text, marker: storeBlock);
      expect(again.managed('dependency_overrides').keys, [
        'just_sprite_editor',
      ]);
      expect(
        again.unmanaged('dependency_overrides').keys,
        isNot(contains('just_sprite_editor')),
      );
      expect(
        again.unmanaged('dependency_overrides').keys,
        contains('just_ui_editor'),
      );
    });

    test('a different entry outside the block is a clash; nothing changes', () {
      final editor = PubspecEditor.parse(overrides, marker: storeBlock);
      expect(
        () => editor.setManaged('dependency_overrides', {
          'just_sprite_editor': sprites,
        }),
        throwsA(
          isA<PubspecEditException>().having((e) => e.names, 'names', [
            'just_sprite_editor',
          ]),
        ),
      );
      expect(editor.text, overrides);
    });

    test('melos-managed names are never written', () {
      expect(
        () => PubspecEditor.parse(
          overrides,
          marker: storeBlock,
        ).setManaged('dependency_overrides', {'digit_data_model': knight}),
        throwsA(isA<PubspecEditException>()),
      );
    });
  });

  group('refused files', () {
    for (final e in {
      'inline section': 'dependencies: {a: ^1.0.0}\n',
      'tabs': 'dependencies:\n\ta: ^1.0.0\n',
      'anchors': 'dependencies:\n  a: &x ^1.0.0\n  b: *x\n',
      'merge keys': 'dependencies:\n  <<: *base\n',
      'a block with no end':
          'dependencies:\n  ${storeBlock.start}\n  a: ^1.0.0\n',
      'a block with no start':
          'dependencies:\n  a: ^1.0.0\n  ${storeBlock.end}\n',
    }.entries) {
      test(e.key, () {
        expect(
          () => PubspecEditor.parse(
            e.value,
            marker: storeBlock,
          ).setManaged('dependencies', {'z': knight}),
          throwsA(isA<PubspecEditException>()),
        );
      });
    }
  });

  test('pub accepts what the editor writes', () async {
    // dart pub get --offline on a project whose pubspec the editor wrote: a
    // path dependency in a managed block, and an override pointing it
    // elsewhere.
    final dir = Directory.systemTemp.createTempSync('pubspec_editor');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final where in [
      'packages/characters/just_art_knight',
      'local/just_art_knight',
    ]) {
      Directory('${dir.path}/$where').createSync(recursive: true);
      File('${dir.path}/$where/pubspec.yaml').writeAsStringSync(
        'name: just_art_knight\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
      );
    }
    final editor =
        PubspecEditor.parse(
            'name: app\r\npublish_to: none\r\nenvironment:\r\n  sdk: ^3.0.0\r\n'
            '# A comment the editor must keep.\r\n',
            marker: storeBlock,
          )
          ..setManaged('dependencies', {'just_art_knight': knight})
          ..setManaged('dependency_overrides', {
            'just_art_knight': const PathDependency('local/just_art_knight'),
          });
    File('${dir.path}/pubspec.yaml').writeAsStringSync(editor.text);
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      File('${dir.path}/.dart_tool/package_config.json').readAsStringSync(),
      contains('local/just_art_knight'),
    );
  });
}

// The generated registry files: what they should hold, and when they are
// out of date.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

import '../support/temp_project.dart';

void main() {
  group('StoreRegistry', () {
    test('generated files checked out with CRLF are up to date', () {
      final dir = tempDir('proj');
      final project = StoreProject(dir.path);
      writeFiles(dir, {
        StoreProject.modulesFile: StoreCodegen.modules(
          const [],
        ).replaceAll('\n', '\r\n'),
        StoreProject.extensionsFile: StoreCodegen.extensions(
          const [],
        ).replaceAll('\n', '\r\n'),
      });
      expect(StoreRegistry.outdated(project), isEmpty);
      expect(StoreRegistry.write(project), isEmpty, reason: 'nothing to write');
    });

    test('only the files a project can compile', () {
      final kit = StoreLock(
        items: {
          'just_kit': const LockedItem(
            version: '^1.0.0',
            kind: ItemKind.runtimeLibrary,
            origin: ItemOrigin.hosted,
          ),
        },
      );
      // Nothing installed and nothing generated yet: nothing is out of date.
      final fresh = StoreProject(tempDir('fresh').path);
      writeFiles(Directory(fresh.root), {'pubspec.yaml': pubspecOf('app')});
      expect(StoreRegistry.wanted(fresh, StoreLock()), isEmpty);
      expect(StoreRegistry.outdated(fresh), isEmpty);
      // A plain Flutter project: no file that imports what it doesn't have.
      expect(StoreRegistry.wanted(fresh, kit), isEmpty);
      // A Just Game Engine project gets both.
      final game = StoreProject(tempDir('game').path);
      writeFiles(Directory(game.root), {
        'pubspec.yaml': pubspecOf(
          'game',
          extra:
              'dependencies:\n  just_game_engine: ^1.0.0\n'
              'dev_dependencies:\n  just_game_engine_editor: ^0.1.0\n',
        ),
      });
      expect(StoreRegistry.wanted(game, kit), {
        StoreProject.modulesFile,
        StoreProject.extensionsFile,
      });
    });
  });
}

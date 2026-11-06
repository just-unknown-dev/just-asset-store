// The store's block in a project's pubspecs.
import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  test("is the store's own, between its markers", () {
    const knight = PathDependency('packages/characters/just_art_knight');
    final editor = PubspecEditor.parse('name: x\n', marker: storeBlock)
      ..setManaged('dependency_overrides', {'just_art_knight': knight});
    expect(
      editor.text,
      'name: x\n'
      '\n'
      'dependency_overrides:\n'
      '  # >>> just_asset_store managed (edit in the Asset Store) >>>\n'
      '  just_art_knight:\n'
      '    path: packages/characters/just_art_knight\n'
      '  # <<< just_asset_store managed <<<\n',
    );
    final back = PubspecEditor.parse(editor.text, marker: storeBlock);
    expect(back.managed('dependency_overrides'), {'just_art_knight': knight});
    expect(back.unmanaged('dependency_overrides'), isEmpty);
  });
}

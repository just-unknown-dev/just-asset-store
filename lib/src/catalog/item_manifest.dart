/// `just_store.json`: what an installed package tells the store about
/// itself.
library;

import '../archive/safe_paths.dart';
import 'json.dart';
import 'names.dart';
import 'plain_text.dart';
import 'semver.dart';
import 'store_index.dart';

/// An editor module the generated `store_modules.g.dart` creates.
final class ModuleEntry {
  /// `ClassName()` from [library].
  const ModuleEntry(this.library, this.className, {this.order = 100});

  /// The `package:` library that declares it.
  final String library;

  /// The module's class. It must have a constructor that takes no
  /// arguments.
  final String className;

  /// Where it goes in the editor's module list; lower first. Order matters:
  /// the first module that provides a level designer wins.
  final int order;

  /// This entry as JSON.
  Map<String, Object?> toJson() => {
    'library': library,
    'class': className,
    'order': order,
  };
}

/// A runtime `ContextExtension` constant the generated
/// `store_extensions.g.dart` lists.
final class ExtensionEntry {
  /// [constant] from [library].
  const ExtensionEntry(this.library, this.constant, {this.order = 100});

  /// The `package:` library that declares it.
  final String library;

  /// The constant, like `PlatformerKit.extension`.
  final String constant;

  /// Where it goes in the list; lower first.
  final int order;

  /// This entry as JSON.
  Map<String, Object?> toJson() => {
    'library': library,
    'const': constant,
    'order': order,
  };
}

/// One of a content item's main files, shown in its details pane.
final class EntryPoint {
  /// [path] (inside the package) of [kind] (`sprite`, `tileset`, `map`…).
  const EntryPoint(this.path, this.kind);

  /// The file inside the package.
  final String path;

  /// What it is.
  final String kind;

  /// This entry point as JSON.
  Map<String, Object?> toJson() => {'path': path, 'kind': kind};
}

/// The manifest every store package carries at its root, as
/// [ItemManifest.fileName].
///
/// It is the store's view of the package: what to register in the editor
/// and the game, which libraries must never ship, which components its
/// scenes would need. The catalog describes an item for browsing; this
/// file describes the installed package itself, so it travels with it.
final class ItemManifest {
  /// A manifest; see the fields for what each part means.
  const ItemManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.kind,
    required this.category,
    this.summary = '',
    this.description,
    this.tags = const [],
    this.author,
    this.permissions = const {},
    this.stage,
    this.replacedBy,
    this.license,
    this.requires = const {},
    this.dependencies = const {},
    this.modules = const [],
    this.editorOnlyLibraries = const [],
    this.extensions = const [],
    this.componentTypes = const [],
    this.setupFile,
    this.setupSnippet,
    this.assetFolders = const [],
    this.entryPoints = const [],
    this.previews = const [],
    this.system = false,
  });

  /// The manifest's file name, at the package root.
  static const String fileName = 'just_store.json';

  /// The newest manifest format this code reads.
  static const int currentSchema = 1;

  /// Reads a manifest from [json]. Throws [StoreFormatException].
  factory ItemManifest.fromJson(JsonFields json) {
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This package needs a newer Asset Store (format $schema).',
      );
    }
    final id = json.string('id');
    final idProblem = StoreNames.idProblem(id);
    if (idProblem != null) throw json.error('id', idProblem);
    final kind = json.choice('kind', ItemKind.byId);
    if (kind == ItemKind.runtimeLibrary) {
      throw json.error(
        'kind',
        'Runtime libraries come from pub.dev and carry no manifest.',
      );
    }
    final category = json.string('category');
    if (!StoreNames.isCategory(category)) {
      throw json.error('category', '"$category" is not a category id.');
    }

    final editor = json.optObject('editor');
    final runtime = json.optObject('runtime');
    final content = json.optObject('content');
    final setup = runtime?.optObject('setup');
    final license = json.optObject('license');

    final modules = [
      for (final m in editor?.objects('modules') ?? const <JsonFields>[])
        ModuleEntry(
          _library(m, id),
          _identifier(m, 'class'),
          order: m.optInt('order') ?? 100,
        ),
    ];
    final extensions = [
      for (final e in runtime?.objects('extensions') ?? const <JsonFields>[])
        ExtensionEntry(
          _library(e, id),
          _identifier(e, 'const'),
          order: e.optInt('order') ?? 100,
        ),
    ];
    final editorOnly = editor?.strings('editorOnlyLibraries') ?? const [];
    for (final lib in editorOnly) {
      if (lib == '*') continue;
      if (!SafePaths.isSafe(lib) || lib.startsWith('lib/')) {
        throw editor!.error(
          'editorOnlyLibraries',
          '"$lib" must be "*" or a path inside lib/, like "editor.dart" or '
              '"src/editor/".',
        );
      }
    }
    final componentTypes = runtime?.strings('componentTypes') ?? const [];
    for (final type in componentTypes) {
      if (!StoreNames.isDottedIdentifier(type)) {
        throw runtime!.error('componentTypes', '"$type" is not a type name.');
      }
    }
    final folders = content?.strings('assetFolders') ?? const [];
    for (final folder in folders) {
      if (!folder.endsWith('/') || !SafePaths.isSafe(folder)) {
        throw content!.error(
          'assetFolders',
          '"$folder" must be a folder inside the package, ending in "/".',
        );
      }
    }
    final entryPoints = [
      for (final e in content?.objects('entryPoints') ?? const <JsonFields>[])
        EntryPoint(_safePath(e, 'path'), e.string('kind')),
    ];

    if (kind == ItemKind.content) {
      if (modules.isNotEmpty || extensions.isNotEmpty) {
        throw json.error('kind', 'A content item has no code to register.');
      }
      if (folders.isEmpty) {
        throw json.error(
          'content',
          'A content item lists its asset folders in content.assetFolders.',
        );
      }
    }
    if (kind == ItemKind.editorExtension && extensions.isNotEmpty) {
      throw json.error(
        'runtime',
        'An editor extension has no runtime part; make it a kit.',
      );
    }
    final permissions = <ItemPermission>{};
    final permissionNames = json.strings('permissions');
    for (var i = 0; i < permissionNames.length; i++) {
      final p = ItemPermission.byId[permissionNames[i]];
      if (p == null) {
        throw StoreFormatException(
          'Expected one of: ${ItemPermission.byId.keys.join(', ')}.',
          where: '${json.where.isEmpty ? '' : '${json.where}.'}permissions[$i]',
        );
      }
      permissions.add(p);
    }
    final stage = ItemStage.optFrom(json, 'stage');
    final replacedBy = json.optString('replacedBy');
    if (replacedBy != null) {
      if (!StoreNames.isId(replacedBy) || replacedBy == id) {
        throw json.error(
          'replacedBy',
          'Name the id of the item that replaces this one.',
        );
      }
      if (stage != ItemStage.deprecated) {
        throw json.error(
          'replacedBy',
          'Only a deprecated item is replaced: set "stage" to "deprecated".',
        );
      }
    }
    if (kind == ItemKind.content && permissions.isNotEmpty) {
      throw json.error('permissions', 'A content item holds no code.');
    }
    final previews = json.strings('previews');
    _checkPreviews(json, previews);
    final author = json.optObject('author');

    return ItemManifest(
      id: id,
      name: plainText(json, 'name', json.string('name')),
      version: json.version('version'),
      kind: kind,
      category: category,
      summary: optPlainText(json, 'summary', json.optString('summary')) ?? '',
      description: optPlainText(
        json,
        'description',
        json.optString('description'),
        lines: true,
      ),
      tags: [for (final t in json.strings('tags')) plainText(json, 'tags', t)],
      author: author == null ? null : StoreAuthor.fromJson(author),
      permissions: permissions,
      stage: stage,
      replacedBy: replacedBy,
      license: license == null ? null : StoreLicense.fromJson(license),
      requires: json.constraints('requires'),
      dependencies: json.constraints('dependencies'),
      modules: modules,
      editorOnlyLibraries: editorOnly,
      extensions: extensions,
      componentTypes: componentTypes,
      setupFile: setup?.optString('file'),
      setupSnippet: setup == null
          ? null
          : optPlainText(
              setup,
              'snippet',
              setup.optString('snippet'),
              lines: true,
            ),
      assetFolders: folders,
      entryPoints: entryPoints,
      previews: previews,
      system: json.flag('system'),
    );
  }

  /// [text] parsed as a manifest. Throws [StoreFormatException].
  factory ItemManifest.parse(String text) =>
      ItemManifest.fromJson(JsonFields.parse(text));

  /// The item id, equal to the package's `name` in its pubspec.
  final String id;

  /// Its display name.
  final String name;

  /// Its version, equal to the pubspec's `version`.
  final Version version;

  /// What it is.
  final ItemKind kind;

  /// Its store category: it lives in `packages/{category}/{id}/` (content)
  /// or `plugins/{category}/{id}/` (an editor extension or a kit).
  final String category;

  /// One line for its card in the store.
  final String summary;

  /// A longer description, plain text.
  final String? description;

  /// Search words.
  final List<String> tags;

  /// Who made it.
  final StoreAuthor? author;

  /// What its code does that a user should know before installing it.
  final Set<ItemPermission> permissions;

  /// How finished this version is. Every plugin (editor tool or kit) names
  /// one; the store and the editor show it.
  final ItemStage? stage;

  /// For a deprecated item: the item that replaces it.
  final String? replacedBy;

  /// Its licence.
  final StoreLicense? license;

  /// The SDKs and core packages it needs.
  final Map<String, VersionConstraint> requires;

  /// The other store items it needs.
  final Map<String, VersionConstraint> dependencies;

  /// The editor modules to register.
  final List<ModuleEntry> modules;

  /// Libraries under `lib/` that must never reach a release build: `*` for
  /// the whole package, or paths like `editor.dart` and `src/editor/`.
  final List<String> editorOnlyLibraries;

  /// The runtime extensions to register.
  final List<ExtensionEntry> extensions;

  /// The component types its runtime adds, so uninstalling can name the
  /// scenes that would stop loading.
  final List<String> componentTypes;

  /// Where its hand-written setup goes, like `lib/game/boot/game_boot.dart`.
  final String? setupFile;

  /// The setup code the store shows after installing it, for what can't be
  /// generated (systems that need the game's own input actions, say).
  final String? setupSnippet;

  /// A content item's asset folders, inside the package, each ending in
  /// `/`. They are what its pubspec's `flutter: assets:` lists.
  final List<String> assetFolders;

  /// A content item's main files.
  final List<EntryPoint> entryPoints;

  /// Pictures for its store page, inside the package; the first is its card
  /// picture. `just store pack` copies them beside the archive, and they go
  /// up with it as release files.
  final List<String> previews;

  /// The most pictures one item shows.
  static const int maxPreviews = 8;

  /// The picture types the store reads, by file extension.
  static const Set<String> previewTypes = {'png', 'jpg', 'jpeg', 'webp'};

  /// Part of the editor itself: shown, updated, never uninstalled.
  final bool system;

  /// Whether nothing of it may ship in a game.
  bool get isEditorOnly =>
      kind == ItemKind.editorExtension || editorOnlyLibraries.contains('*');

  /// This manifest as JSON.
  Map<String, Object?> toJson() => compactJson({
    'schema': currentSchema,
    'id': id,
    'name': name,
    'version': '$version',
    'kind': kind.id,
    'category': category,
    'summary': summary.isEmpty ? null : summary,
    'description': description,
    'tags': tags,
    'author': author?.toJson(),
    'permissions': [
      for (final p in ItemPermission.values)
        if (permissions.contains(p)) p.id,
    ],
    'license': license?.toJson(),
    'requires': {for (final e in requires.entries) e.key: '${e.value}'},
    'dependencies': {for (final e in dependencies.entries) e.key: '${e.value}'},
    'editor': compactJson({
      'modules': [for (final m in modules) m.toJson()],
      'editorOnlyLibraries': editorOnlyLibraries,
    }),
    'runtime': compactJson({
      'extensions': [for (final e in extensions) e.toJson()],
      'componentTypes': componentTypes,
      'setup': compactJson({'file': setupFile, 'snippet': setupSnippet}),
    }),
    'content': compactJson({
      'assetFolders': assetFolders,
      'entryPoints': [for (final e in entryPoints) e.toJson()],
    }),
    'previews': previews,
    'system': system ? true : null,
    'stage': stage?.id,
    'replacedBy': replacedBy,
  });
}

/// A library path inside `lib/` as the generated files may import it:
/// folders and a file of letters, digits, `_`, `-` and `.`, ending in
/// `.dart`. Nothing that could end the import's string or start another
/// directive.
final RegExp _libraryPath = RegExp(
  r'^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*/)*[A-Za-z0-9_][A-Za-z0-9_.-]*\.dart$',
);

String _library(JsonFields json, String id) {
  final lib = json.string('library');
  final prefix = 'package:$id/';
  final rest = lib.startsWith(prefix) ? lib.substring(prefix.length) : null;
  if (rest == null || !_libraryPath.hasMatch(rest) || !SafePaths.isSafe(rest)) {
    throw json.error(
      'library',
      'Expected a library of this package, like "${prefix}editor.dart".',
    );
  }
  return lib;
}

String _identifier(JsonFields json, String key) {
  final text = json.string(key);
  if (!StoreNames.isDottedIdentifier(text)) {
    throw json.error(key, '"$text" is not a Dart name.');
  }
  return text;
}

/// Pictures go up as release files beside the archive, found by file name:
/// each must be an image inside the package, and no two may share a name.
void _checkPreviews(JsonFields json, List<String> previews) {
  if (previews.length > ItemManifest.maxPreviews) {
    throw json.error(
      'previews',
      'At most ${ItemManifest.maxPreviews} pictures; this names '
          '${previews.length}.',
    );
  }
  final names = <String>{};
  for (final path in previews) {
    if (!SafePaths.isSafe(path) || path.endsWith('/')) {
      throw json.error('previews', '"$path" is not a file inside the package.');
    }
    final name = path.split('/').last;
    // GitHub renames release files with other characters on upload.
    if (!RegExp(r'^[A-Za-z0-9_+-][A-Za-z0-9._+-]*$').hasMatch(name)) {
      throw json.error(
        'previews',
        '"$name" must be a plain file name: letters, digits, ".", "_", "+" '
            'and "-".',
      );
    }
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (!ItemManifest.previewTypes.contains(extension)) {
      throw json.error(
        'previews',
        '"$path" is not a picture: use '
            '${ItemManifest.previewTypes.map((t) => '.$t').join(', ')}.',
      );
    }
    if (!names.add(name.toLowerCase())) {
      throw json.error(
        'previews',
        'Two pictures are called "$name": they become release files, found '
            'by name, so each needs its own.',
      );
    }
  }
}

String _safePath(JsonFields json, String key) {
  final path = json.string(key);
  if (!SafePaths.isSafe(path)) {
    throw json.error(key, '"$path" is not a path inside the package.');
  }
  return path;
}

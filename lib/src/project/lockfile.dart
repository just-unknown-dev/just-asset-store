/// `just_store.lock.json`: what the store installed into a project.
library;

import '../catalog/json.dart';
import '../catalog/names.dart';
import '../catalog/store_index.dart';
import '../crypto/sha256.dart';
import '../version.dart';

/// Where an installed item's code comes from.
enum ItemOrigin {
  /// Copied into `packages/{category}/{id}/` by the store.
  vendored,

  /// A checkout the store found already overridden by someone else (a
  /// developer's local repository). Listed, never moved, updated or
  /// hashed.
  linked,

  /// A pub.dev package: a hosted dependency, nothing copied.
  hosted;

  /// The origins, keyed by their JSON names.
  static final Map<String, ItemOrigin> byId = {
    for (final o in values) o.name: o,
  };
}

/// The archive an item was installed from.
final class LockedArchive {
  /// The archive at [url] whose SHA-256 is [sha256].
  const LockedArchive(this.url, this.sha256);

  /// Its URL, as resolved when it was downloaded.
  final String url;

  /// Its SHA-256, 64 lowercase hex digits.
  final String sha256;

  /// This archive as JSON.
  Map<String, Object?> toJson() => {'url': url, 'sha256': sha256};
}

/// One installed item.
final class LockedItem {
  /// An installed item; see the fields for what each part means.
  const LockedItem({
    required this.version,
    required this.kind,
    required this.origin,
    this.category,
    this.path,
    this.direct = true,
    this.source,
    this.archive,
    this.installedAt,
    this.registerModules = true,
    this.registerExtensions = true,
    this.files = const {},
    this.entitlement,
    this.system = false,
  });

  /// Reads one from [json].
  factory LockedItem.fromJson(JsonFields json) {
    final archive = json.optObject('archive');
    if (archive != null && !isSha256Hex(archive.string('sha256'))) {
      throw archive.error('sha256', 'Expected 64 lowercase hex digits.');
    }
    final registry = json.optObject('registry');
    final origin = json.choice('origin', ItemOrigin.byId);
    final path = json.optString('path');
    if (origin != ItemOrigin.hosted && path == null) {
      throw json.error('path', 'A ${origin.name} item records its folder.');
    }
    final files = json.stringMap('files');
    for (final e in files.entries) {
      if (!isSha256Hex(e.value)) {
        throw json.error('files', 'The hash of "${e.key}" is not a SHA-256.');
      }
    }
    return LockedItem(
      version: json.string('version'),
      kind: json.choice('kind', ItemKind.byId),
      origin: origin,
      category: json.optString('category'),
      path: path,
      direct: json.flag('direct', fallback: true),
      source: json.optString('source'),
      archive: archive == null
          ? null
          : LockedArchive(archive.string('url'), archive.string('sha256')),
      installedAt: json.optTime('installedAt'),
      registerModules: registry?.flag('modules', fallback: true) ?? true,
      registerExtensions: registry?.flag('extensions', fallback: true) ?? true,
      files: files,
      entitlement: json.optString('entitlement'),
      system: json.flag('system'),
    );
  }

  /// The installed version; for hosted items, the constraint written into
  /// the pubspec.
  final String version;

  /// What it is.
  final ItemKind kind;

  /// Where its code comes from.
  final ItemOrigin origin;

  /// Its store category.
  final String? category;

  /// Its folder, relative to the project, with `/` between parts.
  final String? path;

  /// Installed on purpose, rather than because another item needs it.
  final bool direct;

  /// The id of the source it came from.
  final String? source;

  /// The archive it was installed from.
  final LockedArchive? archive;

  /// When it was installed or last updated.
  final DateTime? installedAt;

  /// Whether its editor modules go into the generated list. Turn off to
  /// register one by hand, with constructor arguments.
  final bool registerModules;

  /// Whether its runtime extensions go into the generated list.
  final bool registerExtensions;

  /// Each installed file's hash (see `FileHashes`), relative to [path]: how
  /// the store tells a local edit from the file it installed.
  final Map<String, String> files;

  /// For paid items: the order or licence reference. Never a secret.
  final String? entitlement;

  /// Part of the editor itself: never uninstalled.
  final bool system;

  /// Whether it belongs under `dev_dependencies`: editor-only extensions
  /// do, so Flutter leaves their native plugins out of release builds.
  bool get isDevDependency => kind == ItemKind.editorExtension;

  /// A copy with the given fields replaced.
  LockedItem copyWith({
    String? version,
    ItemOrigin? origin,
    String? category,
    String? path,
    bool? direct,
    String? source,
    LockedArchive? archive,
    DateTime? installedAt,
    bool? registerModules,
    bool? registerExtensions,
    Map<String, String>? files,
    String? entitlement,
    bool? system,
  }) => LockedItem(
    version: version ?? this.version,
    kind: kind,
    origin: origin ?? this.origin,
    category: category ?? this.category,
    path: path ?? this.path,
    direct: direct ?? this.direct,
    source: source ?? this.source,
    archive: archive ?? this.archive,
    installedAt: installedAt ?? this.installedAt,
    registerModules: registerModules ?? this.registerModules,
    registerExtensions: registerExtensions ?? this.registerExtensions,
    files: files ?? this.files,
    entitlement: entitlement ?? this.entitlement,
    system: system ?? this.system,
  );

  /// This item as JSON.
  Map<String, Object?> toJson() => compactJson({
    'version': version,
    'kind': kind.id,
    'origin': origin.name,
    'category': category,
    'path': path,
    'direct': direct ? null : false,
    'source': source,
    'archive': archive?.toJson(),
    'installedAt': installedAt?.toUtc().toIso8601String(),
    'registry': registerModules && registerExtensions
        ? null
        : {'modules': registerModules, 'extensions': registerExtensions},
    'files': files,
    'entitlement': entitlement,
    'system': system ? true : null,
  });
}

/// A source the project installed from.
final class LockedSource {
  /// The source [id] at [url].
  const LockedSource(this.id, this.url);

  /// Its id, as items record it.
  final String id;

  /// Its `index.json`.
  final String url;

  /// This source as JSON.
  Map<String, Object?> toJson() => {'id': id, 'url': url};
}

/// The project's record of installed items, committed with it.
///
/// The packages themselves are plain folders and pubspec lines; this file
/// says which of them the store manages, at which version, from where, and
/// how each file looked when installed. `just store restore` rebuilds missing
/// folders from it.
final class StoreLock {
  /// A record of [items] installed from [sources].
  StoreLock({
    this.sources = const [],
    Map<String, LockedItem> items = const {},
    this.generator,
  }) : items = Map.unmodifiable(
         Map.fromEntries(
           items.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
         ),
       );

  /// The lockfile's name, at the project root.
  static const String fileName = 'just_store.lock.json';

  /// The newest lockfile format this code reads.
  static const int currentSchema = 1;

  /// Reads one from [json]. Throws [StoreFormatException].
  factory StoreLock.fromJson(JsonFields json) {
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This project was saved by a newer Asset Store (format $schema).',
      );
    }
    final items = <String, LockedItem>{};
    final raw = json.optObject('items');
    if (raw != null) {
      for (final id in raw.keys) {
        if (!StoreNames.isId(id)) {
          throw raw.error(id, '"$id" is not an item id.');
        }
        final item = LockedItem.fromJson(raw.object(id));
        // The store moves, replaces and restores a vendored item's folder,
        // so it must be the one the store gave it: never a path that leads
        // elsewhere in the project, or out of it.
        if (item.origin == ItemOrigin.vendored) {
          final category = item.category;
          if (category == null || !StoreNames.isCategory(category)) {
            throw raw.error(id, 'A vendored item records its category.');
          }
          final want = 'packages/$category/$id';
          if (item.path != want) {
            throw raw.error(
              id,
              'A vendored item lives in "$want", not "${item.path}".',
            );
          }
        }
        items[id] = item;
      }
    }
    return StoreLock(
      generator: json.optString('generator'),
      sources: [
        for (final s in json.objects('sources'))
          LockedSource(s.string('id'), s.string('url')),
      ],
      items: items,
    );
  }

  /// [text] parsed as a lockfile. Throws [StoreFormatException].
  factory StoreLock.parse(String text) =>
      StoreLock.fromJson(JsonFields.parse(text));

  /// The sources items came from.
  final List<LockedSource> sources;

  /// The installed items, by id, sorted.
  final Map<String, LockedItem> items;

  /// The tool and version that last wrote it.
  final String? generator;

  /// A copy with [id] set to [item].
  StoreLock withItem(String id, LockedItem item) =>
      StoreLock(sources: sources, items: {...items, id: item});

  /// A copy without [id].
  StoreLock without(String id) =>
      StoreLock(sources: sources, items: {...items}..remove(id));

  /// A copy that records [source]: in place of one with the same id, else
  /// after the others. Sources keep the order they were added in, which is
  /// their priority: the first that lists an id is where it comes from.
  StoreLock withSource(LockedSource source) {
    final at = sources.indexWhere((s) => s.id == source.id);
    return StoreLock(
      sources: at < 0 ? [...sources, source] : ([...sources]..[at] = source),
      items: items,
    );
  }

  /// This lockfile as JSON, stamped with [generator].
  Map<String, Object?> toJson({String generator = storeGenerator}) => {
    'schema': currentSchema,
    'generator': generator,
    'sources': [for (final s in sources) s.toJson()],
    'items': {for (final e in items.entries) e.key: e.value.toJson()},
  };

  /// The file's text: canonical JSON.
  String toText() => canonicalJson(toJson());
}

/// What the store writes into the files it generates.
const String storeGenerator = 'just_asset_store $justAssetStoreVersion';

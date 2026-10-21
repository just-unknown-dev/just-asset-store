/// Building a catalog's `index.json` from its repository.
library;

import 'dart:convert';
import 'dart:io';

import '../catalog/json.dart';
import '../catalog/names.dart';
import '../catalog/semver.dart';
import '../catalog/store_index.dart';

/// A built catalog: its index, the pictures to publish beside it, and what
/// was wrong.
final class CatalogBuild {
  /// [index] with [assets] (published path → source file).
  const CatalogBuild(this.index, this.assets);

  /// The catalog.
  final StoreIndex index;

  /// The pictures it refers to, by the path they are published at.
  final Map<String, File> assets;
}

/// A catalog repository that does not build, with every problem found.
final class CatalogBuildException implements Exception {
  /// [problems], one per sentence.
  const CatalogBuildException(this.problems);

  /// What is wrong.
  final List<String> problems;

  @override
  String toString() => problems.map((p) => '- $p').join('\n');
}

/// Builds a catalog from a repository laid out for many publishers:
///
/// ```text
/// catalog.json                     source, categories, maintainers
/// publishers/<publisher>.json      name, GitHub handles, trust
/// items/<id>/item.json             the item, without versions
/// items/<id>/versions/<v>.json     one per version
/// items/<id>/thumbnail.png         its card picture (optional)
/// items/<id>/previews/*.png        details pictures (optional)
/// ```
///
/// An item's trust comes from its publisher's file, never its own, and
/// every rule `index.json` has is checked, so a pull request that builds
/// also installs.
abstract final class CatalogBuilder {
  /// Builds [repo]'s catalog, stamped [now].
  static CatalogBuild build(Directory repo, {DateTime? now}) {
    final problems = <String>[];
    JsonFields? read(File f) {
      try {
        return JsonFields.parse(f.readAsStringSync());
      } on StoreFormatException catch (e) {
        problems.add('${_rel(repo, f)}: ${e.message}');
      } on FileSystemException catch (e) {
        problems.add('${_rel(repo, f)}: ${e.message}');
      }
      return null;
    }

    final catalog = read(File('${repo.path}/catalog.json'));
    if (catalog == null) throw CatalogBuildException(problems);

    final publishers = <String, JsonFields>{};
    final pubDir = Directory('${repo.path}/publishers');
    if (pubDir.existsSync()) {
      for (final f in pubDir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        final json = read(f);
        if (json == null) continue;
        final id = _stem(f);
        if (json.optString('id') != id) {
          problems.add('${_rel(repo, f)}: its "id" must be "$id".');
        }
        publishers[id] = json;
      }
    }

    final items = <Map<String, Object?>>[];
    final assets = <String, File>{};
    final itemsDir = Directory('${repo.path}/items');
    final itemDirs = itemsDir.existsSync()
        ? (itemsDir.listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : <Directory>[];
    for (final dir in itemDirs) {
      final id = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final itemFile = File('${dir.path}/item.json');
      final json = read(itemFile);
      if (json == null) continue;
      final map = <String, Object?>{for (final k in json.keys) k: json.raw(k)};
      if (map['id'] != id) {
        problems.add('items/$id/item.json: its "id" must be "$id".');
      }
      final idProblem = StoreNames.idProblem(id);
      if (idProblem != null) problems.add('items/$id: $idProblem');

      final publisher = map['publisher'] as String? ?? 'just';
      final pub = publishers[publisher];
      if (pub == null) {
        problems.add(
          'items/$id: publisher "$publisher" has no file in publishers/.',
        );
      } else {
        map['trust'] = pub.optString('trust') ?? 'community';
      }

      final versions = <Map<String, Object?>>[];
      final vDir = Directory('${dir.path}/versions');
      if (vDir.existsSync()) {
        for (final f in vDir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.json')) continue;
          final v = read(f);
          if (v == null) continue;
          final stem = _stem(f);
          if (v.optString('version') != stem) {
            problems.add(
              'items/$id/versions/${_name(f)}: its "version" must be "$stem".',
            );
          }
          versions.add({for (final k in v.keys) k: v.raw(k)});
        }
      }
      versions.sort(
        (a, b) => (Version.tryParse('${a['version']}') ?? Version(0, 0, 0))
            .compareTo(Version.tryParse('${b['version']}') ?? Version(0, 0, 0)),
      );
      map['versions'] = versions;

      for (final ext in const ['png', 'jpg', 'jpeg', 'webp']) {
        final thumb = File('${dir.path}/thumbnail.$ext');
        if (thumb.existsSync()) {
          final published = 'items/$id/thumbnail.$ext';
          map['thumbnail'] = published;
          assets[published] = thumb;
          if (thumb.lengthSync() > 512 * 1024) {
            problems.add('$published is over 512 KB; make it smaller.');
          }
          break;
        }
      }
      final previews = Directory('${dir.path}/previews');
      if (previews.existsSync()) {
        final files = previews.listSync().whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        map['previews'] = [
          for (final f in files)
            if (RegExp(r'\.(png|jpe?g|webp|gif)$').hasMatch(f.path))
              'items/$id/previews/${_name(f)}'.also((p) => assets[p] = f),
        ];
      }
      items.add(map);
    }

    final index = <String, Object?>{
      'schema': StoreIndex.currentSchema,
      'source': catalog.raw('source'),
      'generatedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'categories': catalog.raw('categories'),
      'items': items,
    };
    StoreIndex? built;
    try {
      built = StoreIndex.fromJson(JsonFields(jsonDecode(jsonEncode(index))));
    } on StoreFormatException catch (e) {
      // Name the item by id rather than by list position.
      final m = RegExp(r'^items\[(\d+)\](.*)$').firstMatch(e.where);
      problems.add(
        m == null
            ? '${e.where}: ${e.message}'
            : 'items/${items[int.parse(m[1]!)]['id']}${m[2]}: ${e.message}',
      );
    }
    if (problems.isNotEmpty || built == null) {
      throw CatalogBuildException(problems);
    }
    return CatalogBuild(built, assets);
  }

  /// A `CODEOWNERS` file giving each publisher its own items: with branch
  /// protection, only they (or the maintainers) can approve changes there.
  /// A publisher's own file, which says how far the store vouches for it,
  /// is the maintainers' alone: no publisher approves its own trust.
  static String codeowners(Directory repo) {
    final catalog = JsonFields.parse(
      File('${repo.path}/catalog.json').readAsStringSync(),
    );
    final maintainers = catalog.strings('maintainers');
    final handles = <String, List<String>>{};
    final pubDir = Directory('${repo.path}/publishers');
    if (pubDir.existsSync()) {
      for (final f in pubDir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        handles[_stem(f)] = JsonFields.parse(
          f.readAsStringSync(),
        ).strings('github');
      }
    }
    String owners(List<String> h) => {
      ...h,
      ...maintainers,
    }.map((x) => x.startsWith('@') ? x : '@$x').join(' ');
    final out = StringBuffer()
      ..writeln('# GENERATED by `just store index codeowners`. Do not edit.')
      ..writeln('* ${owners(const [])}');
    out.writeln('/publishers/ ${owners(const [])}');
    final itemsDir = Directory('${repo.path}/items');
    if (itemsDir.existsSync()) {
      final dirs = itemsDir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final d in dirs) {
        final id = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final file = File('${d.path}/item.json');
        if (!file.existsSync()) continue;
        final publisher =
            JsonFields.parse(file.readAsStringSync()).optString('publisher') ??
            'just';
        out.writeln('/items/$id/ ${owners(handles[publisher] ?? const [])}');
      }
    }
    return '$out';
  }

  static String _name(File f) => f.uri.pathSegments.last;

  static String _stem(File f) {
    final n = _name(f);
    return n.substring(0, n.length - '.json'.length);
  }

  static String _rel(Directory root, File f) {
    final r = root.absolute.path.replaceAll(r'\', '/');
    final p = f.absolute.path.replaceAll(r'\', '/');
    return p.startsWith('$r/') ? p.substring(r.length + 1) : p;
  }
}

extension<T> on T {
  T also(void Function(T) action) {
    action(this);
    return this;
  }
}

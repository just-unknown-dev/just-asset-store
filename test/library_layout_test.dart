// How lib/ is laid out (README.md, "How the package is laid out"),
// checked from the directives of every file — the rules follow
// just_game_engine's test/library_layout_test.dart, as just_core_cli's do:
// - every file under a top-level folder of lib/src is exported by a public
//   library, through its folder's barrel, or is internal: each of its
//   public declarations is `@internal`;
// - only a folder's barrel or a public library exports, and a barrel only
//   its own folder; a library that holds parts is not a barrel;
// - every top-level folder has its barrel, and `src/web.dart` and
//   `src/version.dart` are the only files directly in lib/src;
// - no export narrows a file of this package with show or hide (a barrel
//   shows the just_core_cli names it passes on);
// - no file imports a barrel that leads back to it;
// - the web-safe features (catalog/, checks/, lockfile/) import no
//   `dart:io`, `dart:ffi` or `dart:isolate`, and no file of a feature that
//   does; just_asset_store.dart reaches the `dart:io` barrels only through
//   `if (dart.library.js_interop) 'src/web.dart'`;
// - no import loop crosses from one feature (a top-level folder of lib/src)
//   to another, no feature imports one in a layer above its own, and the
//   features of one layer don't import each other.
// It reads lib/ from disk, so it runs on the VM only.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' show min;

import 'package:test/test.dart';

const _package = 'package:just_asset_store/';

/// The public libraries, under lib/.
const _public = ['just_asset_store.dart'];

/// Files no public library exports and that are not `@internal` either,
/// with why. Empty: an internal helper says so on its declarations.
const Map<String, String> _internalByList = {};

/// The features — the top-level folders of lib/src — in layers, bottom to
/// top. A feature imports features in its own layer or below, never above;
/// within a layer imports go one way only (no loops). A new top-level
/// folder takes its place here.
const _layers = [
  // Catalogs, items and their manifests.
  ['catalog'],
  // The rules a package must pass; the lockfile and what the store writes.
  ['checks', 'lockfile'],
  // From here on, dart:io. A project on disk; where catalogs and archives
  // come from.
  ['project', 'sources'],
  // The creators' tools: packing and catalogs.
  ['publishing'],
  // Plans, the installer, restore and vendoring.
  ['install'],
  // One project's store.
  ['store'],
  // `just store …`.
  ['commands'],
];

/// The features every platform can use, the web included: they import no
/// `dart:io` (nor `dart:ffi`, `dart:isolate`) and no feature that does.
const _webSafe = ['catalog', 'checks', 'lockfile'];

/// The files directly in lib/src: the web stand-in and the version.
const _flat = ['src/web.dart', 'src/version.dart'];

/// What only a machine has: never imported by a web-safe feature.
const _nativeOnly = ['dart:io', 'dart:ffi', 'dart:isolate', 'dart:html'];

final _directive = RegExp(
  r'^[ \t]*(import|export|part[ \t]+of|part)\b([^;]*);',
  multiLine: true,
);
final _uri = RegExp(r"'([^']+)'");

/// One `import`, `export`, `part` or `part of` of a file, resolved.
final class _Directive {
  _Directive(this.kind, this.uri, this.target, this.text);

  final String kind;
  final String uri;

  /// The file it names, relative to lib/; null for another package's.
  final String? target;

  /// The whole directive, after its keyword.
  final String text;
}

/// A file under lib/: its path from lib/, text and directives.
final class _File {
  _File(this.path, this.text, this.directives);

  final String path;
  final String text;
  final List<_Directive> directives;

  Iterable<_Directive> of(String kind) =>
      directives.where((d) => d.kind == kind);

  /// The library it is part of, or itself.
  String get library =>
      of('part of').map((d) => d.target).nonNulls.firstOrNull ?? path;

  bool get holdsParts => of('part').isNotEmpty;

  /// A top-level folder's barrel: `src/<folder>/<folder>.dart`.
  bool get isBarrel {
    final parts = path.split('/');
    return parts.length == 3 &&
        parts[0] == 'src' &&
        parts[2] == '${parts[1]}.dart';
  }

  bool get isPublic => _public.contains(path);
}

String? _resolve(String from, String uri) {
  if (uri.startsWith(_package)) {
    return uri.substring(_package.length);
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  final segments = from.split('/')..removeLast();
  for (final s in uri.split('/')) {
    if (s == '..') {
      segments.removeLast();
    } else if (s != '.') {
      segments.add(s);
    }
  }
  return segments.join('/');
}

/// Every Dart file under lib/, by path from lib/.
Map<String, _File> _readLib() {
  final root = Directory('lib');
  final files = <String, _File>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final path = f.path.substring(root.path.length + 1).replaceAll(r'\', '/');
    var text = f.readAsStringSync().replaceAll('\r\n', '\n');
    if (text.startsWith('﻿')) text = text.substring(1);
    files[path] = _File(path, text, [
      for (final m in _directive.allMatches(text))
        for (final u in _uri.allMatches(m.group(2)!))
          _Directive(
            m.group(1)!.replaceAll(RegExp(r'\s+'), ' '),
            u.group(1)!,
            _resolve(path, u.group(1)!),
            m.group(2)!.replaceAll(RegExp(r'\s+'), ' ').trim(),
          ),
    ]);
  }
  return files;
}

/// What [from] exports, itself included, following exports onward.
Set<String> _exportedFrom(Map<String, _File> files, Iterable<String> from) {
  final seen = <String>{};
  final stack = [...from];
  while (stack.isNotEmpty) {
    final path = stack.removeLast();
    if (!seen.add(path)) continue;
    for (final d in files[path]?.of('export') ?? const <_Directive>[]) {
      if (d.target != null) stack.add(d.target!);
    }
  }
  return seen;
}

final _typeDeclaration = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*'
  r'(?:class|mixin|enum|typedef|extension\s+type|extension)\s+([A-Za-z_]\w*)',
);

/// The public top-level declarations of [text]: their line and name, and
/// whether `@internal` is among their annotations.
List<({int line, String name, bool internal})> _publicDeclarations(
  String text,
) {
  final lines = text.split('\n');
  final found = <({int line, String name, bool internal})>[];
  var depth = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (depth == 0 &&
        line.isNotEmpty &&
        !line.startsWith(RegExp(r'[\s/*@})\]]')) &&
        !line.startsWith(RegExp(r'(import|export|part|library)\b')) &&
        !line.startsWith(RegExp(r'extension\s+on\b'))) {
      final type = _typeDeclaration.firstMatch(line);
      String? name;
      if (type != null) {
        name = type.group(1);
      } else {
        // A function or variable: the last name before its parameters or
        // value, past its type's own type arguments and a record type.
        var head = line;
        while (head.contains(RegExp(r'<[^<>]*>'))) {
          head = head.replaceAll(RegExp(r'<[^<>]*>'), '');
        }
        if (head.startsWith('(')) {
          var open = 0;
          for (var k = 0; k < head.length; k++) {
            if (head[k] == '(') open++;
            if (head[k] == ')' && --open == 0) {
              head = head.substring(k + 1);
              break;
            }
          }
        }
        head = head.split(RegExp(r'[(=;{]')).first.trim();
        name = RegExp(r'[A-Za-z_]\w*').allMatches(head).lastOrNull?.group(0);
      }
      if (name != null && !name.startsWith('_')) {
        var internal = false;
        for (var j = i - 1; j >= 0; j--) {
          final above = lines[j].trim();
          if (above.startsWith('@')) {
            internal |= RegExp(r'^@internal\b').hasMatch(above);
          } else if (!above.startsWith('///')) {
            break;
          }
        }
        found.add((line: i + 1, name: name, internal: internal));
      }
    }
    // Brace depth, outside strings and comments, so only top-level lines
    // are read as declarations.
    final code = line
        .replaceAll(RegExp(r"'(?:[^'\\]|\\.)*'"), '')
        .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '')
        .split('//')
        .first;
    depth += '{'.allMatches(code).length - '}'.allMatches(code).length;
    if (depth < 0) depth = 0;
  }
  return found;
}

/// The feature a file under lib/ belongs to — its top-level folder of
/// lib/src — or null for a public library or a flat file.
String? _featureOf(String path) {
  final parts = path.split('/');
  return parts.length > 2 && parts[0] == 'src' ? parts[1] : null;
}

/// Every import and export from one feature to another (parts are inside
/// their library's), by (from, to): the directives that make it.
Map<(String, String), List<String>> _featureEdges(Map<String, _File> files) {
  final edges = <(String, String), List<String>>{};
  for (final file in files.values) {
    final from = _featureOf(file.path);
    if (from == null) continue;
    for (final d in [...file.of('import'), ...file.of('export')]) {
      final target = d.target;
      final to = target == null ? null : _featureOf(target);
      if (to == null || to == from) continue;
      (edges[(from, to)] ??= []).add('${file.path} ${d.kind}s ${d.uri}');
    }
  }
  return edges;
}

/// The loops of [graph]: its strongly connected parts of more than one
/// node, each sorted (Tarjan's algorithm).
List<List<String>> _loops(Map<String, Set<String>> graph) {
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final loops = <List<String>>[];
  var next = 0;
  void visit(String v) {
    index[v] = low[v] = next++;
    stack.add(v);
    onStack.add(v);
    for (final w in graph[v] ?? const <String>{}) {
      if (!index.containsKey(w)) {
        visit(w);
        low[v] = min(low[v]!, low[w]!);
      } else if (onStack.contains(w)) {
        low[v] = min(low[v]!, index[w]!);
      }
    }
    if (low[v] != index[v]) return;
    final loop = <String>[];
    String w;
    do {
      w = stack.removeLast();
      onStack.remove(w);
      loop.add(w);
    } while (w != v);
    if (loop.length > 1) loops.add(loop..sort());
  }

  final nodes = {...graph.keys, for (final to in graph.values) ...to}.toList()
    ..sort();
  for (final v in nodes) {
    if (!index.containsKey(v)) visit(v);
  }
  return loops;
}

void main() {
  final files = _readLib();
  final exported = _exportedFrom(files, _public);

  test('every file is exported by a public library or is internal', () {
    final problems = <String>[];
    for (final file in files.values) {
      if (!file.path.startsWith('src/')) continue;
      final internal = !exported.contains(file.library);
      if (_internalByList.containsKey(file.library)) continue;
      for (final d in _publicDeclarations(file.text)) {
        if (internal && !d.internal) {
          problems.add(
            '${file.path}:${d.line} ${d.name} — exported by no public '
            'library: export it from its barrel, or mark it @internal',
          );
        } else if (!internal && d.internal && !_flat.contains(file.path)) {
          problems.add(
            '${file.path}:${d.line} ${d.name} is @internal, but its file is '
            'exported: move it to a file of its own',
          );
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('the explicit internal list names files that exist', () {
    expect([
      for (final path in _internalByList.keys)
        if (!files.containsKey(path)) path,
    ], isEmpty);
  });

  test('only a barrel or a public library exports, a barrel only its '
      'own folder', () {
    final problems = <String>[];
    for (final file in files.values) {
      final exports = file.of('export').toList();
      if (exports.isEmpty || file.isPublic) continue;
      if (!file.isBarrel) {
        problems.add('${file.path} exports, but is not a barrel');
        continue;
      }
      final folder = '${file.path.substring(0, file.path.lastIndexOf('/'))}/';
      for (final d in exports) {
        if (d.target != null && !d.target!.startsWith(folder)) {
          problems.add('${file.path} exports ${d.uri}, outside its folder');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('no export narrows a file of this package with show or hide', () {
    expect([
      for (final file in files.values)
        for (final d in file.of('export'))
          if (d.target != null && RegExp(r'\b(show|hide)\b').hasMatch(d.text))
            '${file.path}: export ${d.text}',
    ], isEmpty);
  });

  test("a barrel passes on another package's names only by name", () {
    expect([
      for (final file in files.values)
        for (final d in file.of('export'))
          if (d.target == null && !d.text.contains(' show '))
            '${file.path}: export ${d.text}',
    ], isEmpty);
  });

  test('every top-level folder has its barrel, and web.dart and version.dart '
      'are the only flat files', () {
    final folders = files.keys.map(_featureOf).nonNulls.toSet();
    expect([
      for (final folder in folders)
        if (!files.containsKey('src/$folder/$folder.dart'))
          'src/$folder has no barrel src/$folder/$folder.dart',
      for (final path in files.keys)
        if (path.startsWith('src/') &&
            path.split('/').length == 2 &&
            !_flat.contains(path))
          '$path is directly in lib/src: give it a feature folder',
    ], isEmpty);
  });

  test('a library that holds parts is not a barrel', () {
    expect([
      for (final file in files.values)
        if (file.holdsParts && file.of('export').isNotEmpty) file.path,
    ], isEmpty);
  });

  test('no file imports a barrel that leads back to it', () {
    final problems = <String>[];
    for (final file in files.values) {
      for (final d in file.of('import')) {
        final target = d.target;
        if (target == null || files[target]?.of('export').isEmpty != false) {
          continue;
        }
        final reached = _exportedFrom(files, [target]);
        if (reached.contains(file.library) && target != file.library) {
          problems.add('${file.path} imports ${d.uri}, which exports it');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('the web-safe features use no dart:io, and no feature that does', () {
    final problems = <String>[];
    for (final file in files.values) {
      final feature = _featureOf(file.path);
      if (!_webSafe.contains(feature)) continue;
      for (final d in [...file.of('import'), ...file.of('export')]) {
        final target = d.target;
        if (target == null) {
          if (_nativeOnly.contains(d.uri)) {
            problems.add('${file.path} imports ${d.uri}');
          }
        } else if (_featureOf(target) case final to?
            when !_webSafe.contains(to)) {
          problems.add('${file.path} imports ${d.uri}, which needs dart:io');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('just_asset_store.dart reaches dart:io only through the web '
      'stand-in', () {
    final problems = <String>[];
    for (final d in files['just_asset_store.dart']!.of('export')) {
      final target = d.target;
      if (target == null || _flat.contains(target)) continue;
      final feature = _featureOf(target);
      if (_webSafe.contains(feature)) continue;
      if (!d.text.contains("if (dart.library.js_interop) 'src/web.dart'")) {
        problems.add('just_asset_store.dart exports ${d.uri} on the web too');
      }
    }
    // And what the web gets instead holds nothing that needs dart:io; nor
    // does the version.
    for (final flat in _flat) {
      expect(files[flat]!.of('import'), isEmpty, reason: flat);
      expect(files[flat]!.of('export'), isEmpty, reason: flat);
    }
    expect(problems, isEmpty);
  });

  final features = _featureEdges(files);
  final layerOf = {
    for (var i = 0; i < _layers.length; i++)
      for (final feature in _layers[i]) feature: i,
  };

  test('every feature has one layer, and every layer names a feature', () {
    final folders = files.keys.map(_featureOf).nonNulls.toSet();
    final listed = [for (final layer in _layers) ...layer];
    expect([
      for (final f in folders)
        if (!listed.contains(f)) '$f has no layer',
      for (final f in listed.toSet())
        if (listed.where((l) => l == f).length > 1) '$f is in two layers',
      for (final f in listed)
        if (!folders.contains(f)) '$f is no folder of lib/src',
    ], isEmpty);
  });

  test('no import loop crosses from one feature to another', () {
    final graph = <String, Set<String>>{};
    for (final (from, to) in features.keys) {
      (graph[from] ??= {}).add(to);
    }
    final problems = <String>[];
    for (final loop in _loops(graph)) {
      problems.add('a loop of ${loop.join(', ')}:');
      for (final MapEntry(key: (from, to), value: why) in features.entries) {
        if (loop.contains(from) && loop.contains(to)) {
          problems.addAll(['  $from -> $to', for (final w in why) '    $w']);
        }
      }
    }
    expect(problems, isEmpty);
  });

  test("the features of one layer don't import each other", () {
    expect([
      for (final MapEntry(key: (from, to), value: why) in features.entries)
        if (layerOf[to] != null && layerOf[to] == layerOf[from])
          for (final w in why) '$from and $to share a layer: $w',
    ], isEmpty);
  });

  test('no feature imports one in a layer above its own', () {
    expect([
      for (final MapEntry(key: (from, to), value: why) in features.entries)
        if ((layerOf[to] ?? -1) > (layerOf[from] ?? _layers.length))
          for (final w in why)
            '$from (layer ${layerOf[from]}) imports $to '
                '(layer ${layerOf[to]}): $w',
    ], isEmpty);
  });

  test('the scanner reads declarations and their annotations', () {
    final found = _publicDeclarations('''
/// Doc.
@internal
final class Kept {
  void method() {}
  static const x = 1;
}

class Plain {}

@internal
Future<int> load() async => 1;

const int limit = 3;

T pick<T>(T a) => a;

List<(String, int)> pairs() => [];

(Map<String, Object?>?, String) split(String s) => (null, s);

extension on int {}

final class _Hidden {}
''');
    expect(found.map((d) => '${d.name}:${d.internal}'), [
      'Kept:true',
      'Plain:false',
      'load:true',
      'limit:false',
      'pick:false',
      'pairs:false',
      'split:false',
    ]);
  });

  test('the loop finder finds a loop', () {
    expect(
      _loops({
        'a': {'b'},
        'b': {'a'},
        'c': {'a'},
      }),
      [
        ['a', 'b'],
      ],
    );
  });
}

/// A catalog as it is published: a small root `index.json` naming pieces,
/// each holding the items of one bucket and named by its SHA-256.
///
/// An editor that read the catalog before asks for the root again (an ETag
/// makes that one small request) and fetches only the pieces it doesn't
/// have: a new version of one item changes one piece. A piece's name is its
/// SHA-256, so it never changes and caches forever.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/sha256.dart';
import 'json.dart';
import 'store_index.dart';

/// The bucket of [buckets] the item [id] belongs in: the first four bytes
/// of its id's SHA-256, as a number, modulo [buckets]. It never changes, so
/// an item stays in its piece.
int catalogBucket(String id, int buckets) {
  final h = Sha256.of(utf8.encode(id));
  // Multiplied, not shifted: the same number on the web.
  final n = ((h[0] * 256 + h[1]) * 256 + h[2]) * 256 + h[3];
  return n % buckets;
}

/// One piece a [CatalogRoot] names.
final class CatalogPieceRef {
  /// The piece holding bucket [bucket]: [size] bytes whose SHA-256 is
  /// [sha256], listing [items] items.
  const CatalogPieceRef({
    required this.bucket,
    required this.sha256,
    required this.size,
    required this.items,
  });

  /// Reads one from [json], for a root of [buckets] buckets.
  factory CatalogPieceRef.fromJson(JsonFields json, int buckets) {
    final bucket = json.integer('bucket');
    if (bucket >= buckets) {
      throw json.error('bucket', 'The catalog has only $buckets buckets.');
    }
    final sha = json.string('sha256');
    if (!isSha256Hex(sha)) {
      throw json.error('sha256', 'Expected 64 lowercase hex digits.');
    }
    final size = json.integer('size', min: 1);
    if (size > CatalogRoot.maxPieceBytes) {
      throw json.error(
        'size',
        'A piece may be at most ${CatalogRoot.maxPieceBytes >> 20} MiB.',
      );
    }
    return CatalogPieceRef(
      bucket: bucket,
      sha256: sha,
      size: size,
      items: json.integer('items', min: 1),
    );
  }

  /// Its bucket.
  final int bucket;

  /// The SHA-256 of its bytes, as 64 lowercase hex digits.
  final String sha256;

  /// Its size in bytes.
  final int size;

  /// How many items it lists.
  final int items;

  /// Where it is, relative to `index.json`.
  String get path => 'catalog/$sha256.json';

  /// This reference as JSON.
  Map<String, Object?> toJson() => {
    'bucket': bucket,
    'sha256': sha256,
    'size': size,
    'items': items,
  };
}

/// A published catalog's `index.json`: who serves it, its categories, what
/// was taken down, and the pieces that list its items.
final class CatalogRoot {
  /// A root naming [pieces], of [buckets] buckets.
  CatalogRoot({
    required this.source,
    required this.categories,
    required this.buckets,
    required this.pieces,
    this.generatedAt,
    this.removed = const [],
    this.featured = const [],
  });

  /// The most buckets a catalog may have.
  static const int maxBuckets = 256;

  /// The largest piece, in bytes.
  static const int maxPieceBytes = 8 << 20;

  /// Whether [json] is a root that names pieces, rather than a catalog
  /// listing its items itself.
  static bool isSplit(JsonFields json) => json.has('pieces');

  /// Reads one from [json]. Throws [StoreFormatException].
  factory CatalogRoot.fromJson(JsonFields json) {
    final schema = json.integer('schema', min: 2);
    if (schema > StoreIndex.currentSchema) {
      throw json.error(
        'schema',
        'This catalog needs a newer Asset Store (format $schema; this one '
            'reads up to ${StoreIndex.currentSchema}).',
      );
    }
    final buckets = json.integer('buckets', min: 1);
    if (buckets > maxBuckets) {
      throw json.error('buckets', 'At most $maxBuckets buckets.');
    }
    final pieces = [
      for (final p in json.objects('pieces'))
        CatalogPieceRef.fromJson(p, buckets),
    ];
    final seen = <int>{};
    for (var i = 0; i < pieces.length; i++) {
      if (!seen.add(pieces[i].bucket)) {
        throw StoreFormatException(
          'Bucket ${pieces[i].bucket} is listed twice.',
          where: 'pieces[$i].bucket',
        );
      }
    }
    return CatalogRoot(
      source: StoreSourceInfo.fromJson(json.object('source')),
      categories: StoreIndex.categoriesFrom(json)
        ..sort((a, b) => a.order.compareTo(b.order)),
      buckets: buckets,
      pieces: pieces,
      generatedAt: json.optTime('generatedAt'),
      removed: StoreIndex.removedFrom(json),
      featured: StoreIndex.featuredFrom(json),
    );
  }

  /// [text] parsed as a root. Throws [StoreFormatException].
  factory CatalogRoot.parse(String text) =>
      CatalogRoot.fromJson(JsonFields.parse(text));

  /// Who serves it.
  final StoreSourceInfo source;

  /// Its categories, sorted.
  final List<StoreCategory> categories;

  /// How many buckets its items are spread over.
  final int buckets;

  /// Its pieces, one per bucket that holds items.
  final List<CatalogPieceRef> pieces;

  /// When it was built.
  final DateTime? generatedAt;

  /// What the store took down.
  final List<RemovedItem> removed;

  /// The ids of the items shown first ([StoreIndex.featured]).
  final List<String> featured;

  /// The catalog these [read] pieces make up: each must be one this root
  /// names, and every piece it names must be there. Throws
  /// [StoreFormatException].
  StoreIndex assemble(List<CatalogPiece> read) {
    final byBucket = {for (final p in read) p.bucket: p};
    final items = <StoreItem>[];
    final skipped = <String>[];
    final known = {for (final c in categories) c.id};
    for (final ref in pieces) {
      final piece = byBucket[ref.bucket];
      if (piece == null) {
        throw StoreFormatException('Piece ${ref.path} is missing.');
      }
      for (var i = 0; i < piece.items.length; i++) {
        final item = piece.items[i];
        if (!known.contains(item.category)) {
          throw StoreFormatException(
            'Category "${item.category}" is not in index.json\'s '
            '"categories".',
            where: 'items[$i].category',
            file: ref.path,
          );
        }
      }
      items.addAll(piece.items);
      skipped.addAll(piece.skipped);
    }
    return StoreIndex.checked(
      source: source,
      categories: categories,
      items: items,
      generatedAt: generatedAt,
      removed: removed,
      skipped: skipped,
      featured: featured,
    );
  }

  /// This root as JSON.
  Map<String, Object?> toJson() => compactJson({
    'schema': StoreIndex.currentSchema,
    'source': source.toJson(),
    'generatedAt': generatedAt?.toUtc().toIso8601String(),
    'categories': [for (final c in categories) c.toJson()],
    'buckets': buckets,
    'pieces': [for (final p in pieces) p.toJson()],
    'removed': [for (final r in removed) r.toJson()],
    'featured': featured.isEmpty ? null : featured,
  });
}

/// One piece of a published catalog: the items of one bucket.
final class CatalogPiece {
  /// The piece of [bucket], listing [items] (and leaving out [skipped]).
  const CatalogPiece(this.bucket, this.items, {this.skipped = const []});

  /// [bytes], the piece [ref] names in a root of [buckets] buckets: checked
  /// against [ref] — its size and SHA-256, its bucket, how many items it
  /// lists, and that each belongs in it. Throws [StoreFormatException]
  /// naming the piece's file.
  factory CatalogPiece.read(
    Uint8List bytes,
    CatalogPieceRef ref, {
    required int buckets,
  }) {
    if (bytes.length != ref.size || Sha256.hexOf(bytes) != ref.sha256) {
      throw StoreFormatException(
        'It is not the piece index.json names (its size or SHA-256 '
        'differs).',
        file: ref.path,
      );
    }
    try {
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        throw const StoreFormatException('It is not UTF-8 text.');
      }
      final json = JsonFields.parse(text);
      final schema = json.integer('schema', min: 2);
      if (schema > StoreIndex.currentSchema) {
        throw json.error('schema', 'A newer catalog format ($schema).');
      }
      if (json.integer('bucket') != ref.bucket) {
        throw json.error('bucket', 'index.json says bucket ${ref.bucket}.');
      }
      final skipped = <String>[];
      final items = StoreIndex.itemsFrom(json, skipped);
      if (items.length + skipped.length != ref.items) {
        throw json.error(
          'items',
          'It lists ${items.length + skipped.length} items; index.json says '
              '${ref.items}.',
        );
      }
      for (var i = 0; i < items.length; i++) {
        if (catalogBucket(items[i].id, buckets) != ref.bucket) {
          throw StoreFormatException(
            '"${items[i].id}" belongs in another bucket.',
            where: 'items[$i].id',
          );
        }
      }
      return CatalogPiece(ref.bucket, items, skipped: skipped);
    } on StoreFormatException catch (e) {
      throw e.file == null ? e.inFile(ref.path) : e;
    }
  }

  /// Its bucket.
  final int bucket;

  /// Its items.
  final List<StoreItem> items;

  /// The ids of items left out because this version doesn't know their
  /// kind.
  final List<String> skipped;
}

/// A catalog written as it is published: `index.json` and its pieces.
final class CatalogFiles {
  CatalogFiles._(this.root, this.rootText, this.pieces);

  /// [index] split into [buckets] pieces. The same items always make the
  /// same pieces, byte for byte: items are sorted by id and written as
  /// canonical JSON, and only the root says when it was made
  /// ([generatedAt], or [index]'s own).
  ///
  /// Throws [StoreFormatException] when one bucket would make a piece over
  /// [CatalogRoot.maxPieceBytes]: use more buckets.
  factory CatalogFiles.of(
    StoreIndex index, {
    int buckets = 32,
    DateTime? generatedAt,
  }) {
    if (buckets < 1 || buckets > CatalogRoot.maxBuckets) {
      throw ArgumentError.value(buckets, 'buckets');
    }
    final grouped = <int, List<StoreItem>>{};
    for (final item in index.items) {
      grouped.putIfAbsent(catalogBucket(item.id, buckets), () => []).add(item);
    }
    final refs = <CatalogPieceRef>[];
    final pieces = <String, Uint8List>{};
    for (final bucket in grouped.keys.toList()..sort()) {
      final items = grouped[bucket]!..sort((a, b) => a.id.compareTo(b.id));
      final bytes = utf8.encode(
        canonicalJson({
          'schema': StoreIndex.currentSchema,
          'bucket': bucket,
          'items': [for (final i in items) i.toJson()],
        }, pretty: false),
      );
      if (bytes.length > CatalogRoot.maxPieceBytes) {
        throw StoreFormatException(
          'Bucket $bucket would be ${bytes.length} bytes; use more than '
          '$buckets buckets.',
        );
      }
      final ref = CatalogPieceRef(
        bucket: bucket,
        sha256: Sha256.hexOf(bytes),
        size: bytes.length,
        items: items.length,
      );
      refs.add(ref);
      pieces[ref.path] = bytes;
    }
    final root = CatalogRoot(
      source: index.source,
      categories: index.categories,
      buckets: buckets,
      pieces: refs,
      generatedAt: generatedAt ?? index.generatedAt,
      removed: index.removed,
      featured: index.featured,
    );
    return CatalogFiles._(root, canonicalJson(root.toJson()), pieces);
  }

  /// The root.
  final CatalogRoot root;

  /// The root as `index.json` text.
  final String rootText;

  /// The pieces' bytes, by the path the root names them at
  /// (`catalog/<sha256>.json`).
  final Map<String, Uint8List> pieces;

  /// Every file to publish, by path: `index.json` and the pieces.
  Map<String, Uint8List> get files => {
    'index.json': utf8.encode(rootText),
    ...pieces,
  };
}

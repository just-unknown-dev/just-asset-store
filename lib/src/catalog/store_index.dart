/// A catalog's `index.json`: what a store source offers.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'item_traits.dart';
import 'plain_text.dart';
import 'store_item.dart';

/// A heading items are grouped under, and the folder they install into.
final class StoreCategory {
  /// The category [id], shown as [label], sorted by [order].
  const StoreCategory(this.id, this.label, {this.order = 100});

  /// Reads one from [json].
  factory StoreCategory.fromJson(JsonFields json) {
    final id = json.string('id');
    if (!PackageNames.isCategory(id)) {
      throw json.error('id', '"$id" is not a category id.');
    }
    return StoreCategory(
      id,
      plainText(json, 'label', json.string('label')),
      order: json.optInt('order') ?? 100,
    );
  }

  /// Its id, used in folder names.
  final String id;

  /// Its display name.
  final String label;

  /// Where it sorts; lower first.
  final int order;

  /// This category as JSON.
  Map<String, Object?> toJson() => {'id': id, 'label': label, 'order': order};
}

/// Who serves a catalog.
final class StoreSourceInfo {
  /// The source [id], shown as [name].
  const StoreSourceInfo(this.id, this.name, {this.homepage});

  /// Reads one from [json].
  factory StoreSourceInfo.fromJson(JsonFields json) {
    final id = json.string('id');
    if (!_sourceId.hasMatch(id)) {
      throw json.error(
        'id',
        'A source id is lowercase letters, digits, ".", "_" and "-".',
      );
    }
    return StoreSourceInfo(
      id,
      plainText(json, 'name', json.string('name')),
      homepage: optPlainText(json, 'homepage', json.optString('homepage')),
    );
  }

  static final RegExp _sourceId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  /// Its id, recorded in the lockfile beside what came from it.
  final String id;

  /// Its display name.
  final String name;

  /// Its web page.
  final String? homepage;

  /// This source as JSON.
  Map<String, Object?> toJson() =>
      compactJson({'id': id, 'name': name, 'homepage': homepage});
}

/// An item the store took down — malware, a stolen asset — and why. It is
/// no longer offered, and projects that installed it are warned.
final class RemovedItem {
  /// [id] was removed for [reason].
  const RemovedItem(this.id, this.reason);

  /// Reads one from [json].
  factory RemovedItem.fromJson(JsonFields json) {
    final id = json.string('id');
    final problem = PackageNames.idProblem(id);
    if (problem != null) throw json.error('id', problem);
    return RemovedItem(id, plainText(json, 'reason', json.string('reason')));
  }

  /// The item's id.
  final String id;

  /// Why, in a sentence.
  final String reason;

  /// This removal as JSON.
  Map<String, Object?> toJson() => {'id': id, 'reason': reason};
}

/// A catalog: what a store source offers. It is published as a small
/// `index.json` naming pieces (see `CatalogFiles`), or — small catalogs,
/// tests — as one `index.json` listing every item, which [fromJson] reads.
final class StoreIndex {
  /// A catalog from [source] listing [items] under [categories]. Use
  /// [StoreIndex.checked] for items not yet checked against each other.
  StoreIndex({
    required this.source,
    required this.categories,
    required this.items,
    this.generatedAt,
    this.removed = const [],
    this.skipped = const [],
    this.featured = const [],
  }) : _byId = {for (final i in items) i.id: i};

  /// A catalog of [items], once no id is listed twice and every item's
  /// category is one of [categories] (which come out sorted). Throws
  /// [JsonFormatException] naming the item as `items[N]`.
  factory StoreIndex.checked({
    required StoreSourceInfo source,
    required List<StoreCategory> categories,
    required List<StoreItem> items,
    DateTime? generatedAt,
    List<RemovedItem> removed = const [],
    List<String> skipped = const [],
    List<String> featured = const [],
  }) {
    _check(items, categories);
    return StoreIndex(
      source: source,
      categories: [...categories]..sort((a, b) => a.order.compareTo(b.order)),
      items: items,
      generatedAt: generatedAt,
      removed: removed,
      skipped: skipped,
      featured: featured,
    );
  }

  static void _check(List<StoreItem> items, List<StoreCategory> categories) {
    final ids = <String>{};
    final known = {for (final c in categories) c.id};
    for (var i = 0; i < items.length; i++) {
      if (!ids.add(items[i].id)) {
        throw JsonFormatException(
          '"${items[i].id}" is listed twice.',
          where: 'items[$i].id',
        );
      }
      if (!known.contains(items[i].category)) {
        throw JsonFormatException(
          'Category "${items[i].category}" is not in "categories".',
          where: 'items[$i].category',
        );
      }
    }
  }

  /// The ids of the items left out because this version doesn't know their
  /// kind: an older store reading a newer catalog.
  final List<String> skipped;

  /// The newest catalog format this code reads.
  static const int currentSchema = 2;

  /// Reads a catalog that lists its items itself. Throws
  /// [JsonFormatException], also for a catalog split into pieces, which
  /// only a store source can read.
  factory StoreIndex.fromJson(JsonFields json) {
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This catalog needs a newer Asset Store (format $schema; this one '
            'reads up to $currentSchema).',
      );
    }
    if (json.has('pieces')) {
      throw json.error(
        'pieces',
        'This catalog is split into pieces; read it through its source.',
      );
    }
    final categories = categoriesFrom(json);
    final skipped = <String>[];
    final items = itemsFrom(json, skipped);
    _check(items, categories);
    return StoreIndex(
      source: StoreSourceInfo.fromJson(json.object('source')),
      categories: categories..sort((a, b) => a.order.compareTo(b.order)),
      items: items,
      generatedAt: json.optTime('generatedAt'),
      removed: removedFrom(json),
      skipped: skipped,
      featured: featuredFrom(json),
    );
  }

  /// The ids listed at `featured` in [json]: any that is not an id is left
  /// out (it names nothing).
  static List<String> featuredFrom(JsonFields json) => [
    for (final id in json.strings('featured'))
      if (PackageNames.isId(id)) id,
  ];

  /// The categories listed at `categories` in [json].
  static List<StoreCategory> categoriesFrom(JsonFields json) => [
    for (final c in json.objects('categories')) StoreCategory.fromJson(c),
  ];

  /// The removals listed at `removed` in [json].
  static List<RemovedItem> removedFrom(JsonFields json) => [
    for (final r in json.objects('removed')) RemovedItem.fromJson(r),
  ];

  /// The items listed at `items` in [json]. An item of a kind this version
  /// doesn't know (a newer catalog's) is left out, its id added to
  /// [skipped] — not a reason to refuse the whole catalog.
  static List<StoreItem> itemsFrom(JsonFields json, List<String> skipped) => [
    for (final i in json.objects('items'))
      if (i.raw('kind') case final String k
          when k.isNotEmpty && !ItemKind.byId.containsKey(k))
        ?_skip(i, skipped)
      else
        StoreItem.fromJson(i),
  ];

  static StoreItem? _skip(JsonFields item, List<String> skipped) {
    skipped.add('${item.raw('id')}');
    return null;
  }

  /// [text] parsed as a catalog that lists its items itself. Throws
  /// [JsonFormatException].
  factory StoreIndex.parse(String text) =>
      StoreIndex.fromJson(JsonFields.parse(text));

  /// Who serves it.
  final StoreSourceInfo source;

  /// Its categories, sorted.
  final List<StoreCategory> categories;

  /// Its items.
  final List<StoreItem> items;

  /// When it was built.
  final DateTime? generatedAt;

  /// What the store took down.
  final List<RemovedItem> removed;

  /// The ids of the items its makers show first, in order: the website's
  /// featured shelf. An id it doesn't list names nothing.
  final List<String> featured;

  /// The [featured] items it lists, in order.
  List<StoreItem> get featuredItems => [for (final id in featured) ?_byId[id]];

  final Map<String, StoreItem> _byId;

  /// The item with [id], or null.
  StoreItem? item(String id) => _byId[id];

  /// Why the item [id] was taken down, when it was.
  RemovedItem? removal(String id) {
    for (final r in removed) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The category with [id], or null.
  StoreCategory? category(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// This catalog as one JSON object listing every item.
  Map<String, Object?> toJson() => compactJson({
    'schema': currentSchema,
    'source': source.toJson(),
    'generatedAt': generatedAt?.toUtc().toIso8601String(),
    'categories': [for (final c in categories) c.toJson()],
    'items': [for (final i in items) i.toJson()],
    'removed': [for (final r in removed) r.toJson()],
    'featured': featured.isEmpty ? null : featured,
  });
}

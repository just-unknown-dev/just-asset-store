/// Every enabled source's catalog, merged: what a plan picks items from.
library;

import '../catalog/item_traits.dart';
import '../catalog/store_index.dart';
import '../catalog/store_item.dart';
import '../sources/store_source.dart';

/// An item as one source offers it.
final class CatalogEntry {
  /// [item] from the source [sourceId].
  const CatalogEntry(this.sourceId, this.item, {this.source});

  /// The source's id, as the lockfile records it.
  final String sourceId;

  /// Where to download from; null in tests that only plan.
  final StoreSource? source;

  /// The item.
  final StoreItem item;
}

/// Every enabled source's catalog, merged. When two sources list the same
/// id, the first source wins and the clash is reported.
///
/// How far the store vouches for an item ([StoreItem.trust]) is what its
/// catalog says only when that catalog may say it ([StoreSource.vouches]):
/// the official catalog, a catalog in a folder on this machine that the
/// user chose (one being built or tried out — not one only the project's
/// lockfile names), or one made in memory. Every other catalog's items are
/// community items, whatever it claims.
final class StoreCatalog {
  /// The catalogs, in priority order.
  StoreCatalog(List<(String, StoreSource?, StoreIndex)> catalogs) {
    for (final (sourceId, source, index) in catalogs) {
      final vouches = _vouches(source);
      for (var item in index.items) {
        final existing = _entries[item.id];
        if (existing != null) {
          clashes.add(
            '"${item.id}" is in both ${existing.sourceId} and $sourceId; '
            'the store uses ${existing.sourceId}.',
          );
          continue;
        }
        if (!vouches && item.trust != TrustLevel.community) {
          item = item.withTrust(TrustLevel.community);
        }
        _entries[item.id] = CatalogEntry(sourceId, item, source: source);
      }
      for (final c in index.categories) {
        _categories.putIfAbsent(c.id, () => c);
      }
      for (final r in index.removed) {
        _removedBy['$sourceId/${r.id}'] = r;
        if (vouches) _removedVouched.putIfAbsent(r.id, () => r);
      }
    }
  }

  final Map<String, CatalogEntry> _entries = {};
  final Map<String, StoreCategory> _categories = {};
  final Map<String, RemovedItem> _removedBy = {};
  final Map<String, RemovedItem> _removedVouched = {};

  /// Why the store took down the item [id], when it did: as the catalog it
  /// was installed from ([source]) says, or a catalog that may vouch for
  /// items (the official one, a folder on this machine). Another catalog
  /// can't take down what it didn't provide.
  RemovedItem? removal(String id, {String? source}) =>
      (source == null ? null : _removedBy['$source/$id']) ??
      _removedVouched[id];

  /// Ids two sources both list.
  final List<String> clashes = [];

  /// The entry for [id], or null.
  CatalogEntry? entry(String id) => _entries[id];

  /// Every entry.
  Iterable<CatalogEntry> get entries => _entries.values;

  /// Every category, sorted.
  List<StoreCategory> get categories =>
      _categories.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  /// Whether [source]'s catalog may say how far the store vouches for its
  /// items ([StoreSource.vouches]); a catalog with no source is one a test
  /// made.
  static bool _vouches(StoreSource? source) => source?.vouches ?? true;
}

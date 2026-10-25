/// Where an item comes from, as the store tells it: never what the item
/// says about itself.
library;

import '../catalog/store_index.dart';
import '../project/lockfile.dart';
import 'planner.dart';

/// Where an item comes from, and so who stands behind it.
enum ItemSource {
  /// The store's own catalog vouches for it: made by Just Unknown.
  official('official', 'Official'),

  /// Listed in another catalog.
  thirdParty('third-party', 'Third Party'),

  /// Straight from a GitHub release that no catalog lists.
  unlisted('unlisted', 'Unlisted'),

  /// The project's own checkout, linked in (`just store link`).
  local('local', 'Local');

  const ItemSource(this.id, this.label);

  /// The name used in JSON.
  final String id;

  /// What it is called on a badge.
  final String label;

  /// The source id a GitHub release's items are recorded under starts with
  /// this.
  static const String githubPrefix = 'github:';

  /// Where an item comes from: what the project recorded when it
  /// [installed] it, else the catalog [entry] that offers it.
  static ItemSource of({CatalogEntry? entry, LockedItem? installed}) {
    if (installed != null) return ofInstalled(installed);
    if (entry == null) return thirdParty;
    if (entry.sourceId.startsWith(githubPrefix)) return unlisted;
    return entry.item.trust == TrustLevel.official ? official : thirdParty;
  }

  /// Where the project's installed item [item] came from, as its lockfile
  /// records it.
  static ItemSource ofInstalled(LockedItem item) {
    if (item.origin == ItemOrigin.linked) return local;
    if (item.source?.startsWith(githubPrefix) ?? false) return unlisted;
    return item.official ? official : thirdParty;
  }
}

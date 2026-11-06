/// Catalogs and manifests: a catalog's `index.json` and its pieces, its
/// items and their versions, a package's `just_store.json`, claim codes and
/// the reserved names — and the just_core_cli names they are read with.
/// Web-safe.
library;

export 'package:just_core_cli/just_core_cli.dart'
    show
        JsonFields,
        JsonFormatException,
        PackageNames,
        Sha256,
        Version,
        VersionConstraint,
        canonicalJson,
        compactJson,
        isSha256Hex;

export 'catalog_files.dart';
export 'claim_code.dart';
export 'item_details.dart';
export 'item_manifest.dart';
export 'item_traits.dart';
export 'just_release.dart';
export 'reserved_names.dart';
export 'store_index.dart';
export 'store_item.dart';

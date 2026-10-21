/// Reading and writing the store's JSON files, with just_core_cli's
/// [JsonFields], which the store builds on.
library;

import 'package:just_core_cli/just_core_cli.dart'
    show JsonFields, JsonFormatException;

export 'package:just_core_cli/just_core_cli.dart'
    show JsonFields, JsonFormatException, canonicalJson, compactJson;

/// A catalog, manifest or lockfile that is not what the store reads: the
/// store's name for [JsonFormatException], which says which field and, with
/// `inFile`, which file.
typedef StoreFormatException = JsonFormatException;

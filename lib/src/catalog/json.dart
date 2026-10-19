/// Moved to `package:just_core_cli`, which the store now builds on. Re-exported
/// here so the store's own imports, and the editor's, stay as they were.
library;

import 'package:just_core_cli/project.dart' show JsonFormatException;

export 'package:just_core_cli/project.dart'
    show JsonFields, JsonFormatException, canonicalJson, compactJson;

/// The store's name for [JsonFormatException], kept so code that throws or
/// catches it still does.
typedef StoreFormatException = JsonFormatException;

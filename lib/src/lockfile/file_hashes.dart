/// File hashes in the store's lockfile: a local edit told from what the
/// store installed. Moved from just_core_cli 0.1.2 unchanged, so every
/// hash in a `just_store.lock.json` stays the same; the folder walk is
/// `FolderHashes`, in `project/`.
library;

import 'package:just_core_cli/just_core_cli.dart' show Sha256;

/// Hashes files so a tool can tell a local edit from what it installed.
abstract final class FileHashes {
  /// Extensions hashed as text: line endings are ignored, so a checkout
  /// that turned LF into CRLF (git's core.autocrlf) is not an edit.
  static const Set<String> textExtensions = {
    'json', 'yaml', 'yml', 'dart', 'md', 'txt', 'tmx', 'tsx', 'tmj', 'tsj', //
    'tx', 'xml', 'csv', 'svg', 'glsl', 'frag', 'vert', 'yarn', 'html', 'css',
    'js', 'atlas', 'fnt', 'gitignore', 'pubignore', 'gitattributes',
  };

  /// Whether [path] is hashed as text.
  static bool isText(String path) {
    final name = path.split('/').last.toLowerCase();
    if (name == 'license' || name == 'licence' || name == 'changelog') {
      return true;
    }
    final dot = name.lastIndexOf('.');
    return dot >= 0 && textExtensions.contains(name.substring(dot + 1));
  }

  /// The hash of [bytes], the content of [path]: SHA-256, with CRLF read as
  /// LF for text files.
  static String of(String path, List<int> bytes) {
    if (!isText(path)) return Sha256.hexOf(bytes);
    final out = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0D && i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
        continue;
      }
      out.add(bytes[i]);
    }
    return Sha256.hexOf(out);
  }

  /// Whether [relative] is inside a folder tools make — `.dart_tool`,
  /// `.git` or `.idea` at any depth, `build` at the top — or is a pub
  /// lockfile or Flutter's plugin list.
  static bool isToolPath(String relative) {
    final parts = relative.split('/');
    // A package's own build output is `build/` at its root; a `build`
    // folder deeper down is the package's content.
    return parts.first == 'build' ||
        parts.any((p) => const {'.dart_tool', '.git', '.idea'}.contains(p)) ||
        relative == 'pubspec.lock' ||
        relative == '.flutter-plugins' ||
        relative == '.flutter-plugins-dependencies';
  }
}

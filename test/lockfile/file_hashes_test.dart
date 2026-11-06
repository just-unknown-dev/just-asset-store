// The file hashes the lockfile records. Web-safe: they are read on every
// platform.

import 'dart:convert';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:test/test.dart';

void main() {
  group('FileHashes', () {
    test('text ignores CRLF, binary does not', () {
      final lf = utf8.encode('a\nb\n');
      final crlf = utf8.encode('a\r\nb\r\n');
      expect(FileHashes.of('x.json', lf), FileHashes.of('x.json', crlf));
      expect(FileHashes.of('LICENSE', lf), FileHashes.of('LICENSE', crlf));
      expect(FileHashes.of('x.png', lf), isNot(FileHashes.of('x.png', crlf)));
      // A lone CR is content, not a line ending.
      expect(
        FileHashes.of('x.txt', utf8.encode('a\rb')),
        isNot(FileHashes.of('x.txt', utf8.encode('ab'))),
      );
    });

    test('are the hashes every just_store.lock.json already holds', () {
      // SHA-256 of the bytes, text read with LF line endings: pinned, so
      // the hashes in committed lockfiles never change.
      expect(
        FileHashes.of('x.json', utf8.encode('a\r\nb\r\n')),
        '911169ddaaf146aff539f58c26c489af3b892dff0fe283c1c264c65ae5aa59a2',
      );
      expect(
        FileHashes.of('sprites/a.JSON', utf8.encode('{"a": 1}\n')),
        'e8c628edc9968ef0c668f54e0ba2636b35503357eb1aca0ddc828aeace432f67',
      );
      expect(
        FileHashes.of('x.png', [0, 1, 2, 13, 10, 255]),
        'b9bdb04937ab74bc792feebc816ea37193b3a56df1af99210f580e35ea6a61cb',
      );
      expect(
        FileHashes.of('LICENSE', const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(FileHashes.isToolPath('build/x'), isTrue);
      expect(FileHashes.isToolPath('assets/build/x'), isFalse);
      expect(FileHashes.isToolPath('a/.dart_tool/x'), isTrue);
    });
  });
}

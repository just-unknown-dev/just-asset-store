/// Claim codes: how a GitHub repository says which store account may
/// publish its package.
library;

import 'dart:convert';

import '../crypto/sha256.dart';

/// The claim code of the GitHub account whose numeric id is [githubId].
///
/// Written into a package's `just_release.json`, it says that account may
/// publish the package. Anyone can work out anyone's code (the store's
/// website shows each creator theirs); what matters is that only someone
/// who can push to the repository can put it in a release, so a stranger
/// can't submit someone else's package.
String claimCode(int githubId) {
  if (githubId < 1) {
    throw ArgumentError.value(githubId, 'githubId', 'Not a GitHub account id');
  }
  final hash = Sha256.of(utf8.encode('just-asset-store/claim/v1/$githubId'));
  return 'jas1-${_base32(hash).substring(0, 16)}';
}

/// Whether [text] is written as a claim code.
bool isClaimCode(String text) => _claim.hasMatch(text);

final RegExp _claim = RegExp(r'^jas1-[a-z2-7]{16}$');

/// [bytes] in lowercase base32 (RFC 4648), without padding.
String _base32(List<int> bytes) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(alphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

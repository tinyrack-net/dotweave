/// Pure-Dart age v1 file encryption (X25519 recipients only).
///
/// The wire-format internals (header, stanza, STREAM, bech32, primitives) stay
/// under `src/` so no dotweave type can leak into them and no consumer can
/// depend on them: the boundary is what keeps this module publishable.
library;

export 'src/age.dart';

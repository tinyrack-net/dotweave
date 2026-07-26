# age testkit vectors (vendored subset)

Representative subset of the official C2SP CCTV age test vectors, used by
`test/crypto/age/testkit_test.dart`.

- Upstream: https://github.com/C2SP/CCTV (`age/testdata/`)
- Upstream commit: `1e3d2860d46e94e777e1b17c7a6f2436387e3ecc`
- License: upstream permits vendoring without attribution (CC0-like terms; see
  upstream repository).

Each file is a textual header (`key: value` lines: `expect`, `payload`,
`file key`, `identity`, `passphrase`, `armored`, `compressed`), an empty line,
and then the age file itself (zlib-compressed when `compressed: zlib`).

The subset covers: X25519 success cases (including grease stanzas, multiple
recipients, and unusual-but-valid stanza characters), armor success and
failure variants (CRLF, surrounding whitespace, garbage, missing padding),
HMAC and header failures, STREAM payload failures (bad tag, missing final
flag, short chunk, empty last chunk, trailing garbage), no-match cases, and
scrypt vectors (asserted to fail with the unsupported-passphrase error, since
this implementation intentionally does not support passphrase encryption).

Do not edit these files; refresh them from upstream instead.

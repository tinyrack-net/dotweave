# TS → Dart parity decisions

Every intentional behavioral divergence from `packages/cli` (TypeScript) discovered
during the port is recorded here so the cutover review is a checklist, not
archaeology. Keep entries short: what differs, why, and which tests pin it.

## Conventions

- Repo paths always use `package:path` `posix` context; local paths use the
  native context — mirrors `node:path.posix` vs `node:path` usage in TS.
- JSON files (`manifest.jsonc`, `settings.jsonc`) must serialize byte-identically
  to `JSON.stringify(config, null, 2)` + trailing newline. Pinned by golden
  tests against TS-generated fixtures (M1).

## Divergences

- **Sort order (`localeCompare`)**: TS sorts with ICU collation via
  `String.prototype.localeCompare`. Dart port uses
  `lib/src/lib/collation.dart` `compareLocaleLike` — case-insensitive primary
  with lowercase-first tiebreak. Matches ICU for ASCII filenames; full ICU
  punctuation weighting and non-ASCII script ordering are approximated.
  Pinned by `test/lib/collation_test.dart`.
- **`wrapUnknownError` stringification of non-error values**: TS renders
  `String({...})` as `[object Object]`; Dart renders the map's `toString()`
  (`{code: 123}`). Same intent (opaque fallback), different text. Pinned by
  `test/lib/error_test.dart`.
- **JS vs Dart `trim()`**: Dart's `trim()` does not strip U+00A0 (NBSP) while
  JS does. Affects only pathological manifest values; accepted.
- **`PlatformStringValue.default` → `defaultValue`**: `default` is reserved in
  Dart. JSON I/O still reads/writes the `default` key.
- **node:path vs package:path edges** (handled at every call site, commented):
  `relative(x, x)` returns `'.'` not `''`; cross-drive `relative` throws
  `PathException` instead of returning an absolute path (mapped to the same
  outcomes); `resolve` is emulated via `normalize(joinAll([current, ...]))`;
  `p.posix.normalize` strips trailing slashes node keeps.
- **`EffectiveSyncConfig` is a standalone class**, not
  `ResolvedSyncConfig & {age}` — Dart cannot express the TS intersection
  override. Bridges: `_toResolvedSyncConfig` views and the
  `ArtifactOwnershipConfig` record typedef in `repo_artifacts.dart`.
- **Wrapped age error detail lines** read
  `AgeException(code): message` instead of the npm library's message text
  (inherent to swapping the age implementation; no test asserts them).
- **`List.sort` is unstable** vs V8's stable sort. Each affected sort was
  audited: ties are impossible (unique keys) or outcome-equivalent
  (inheritance ordering by strict path length).
- **FS error semantics**: `dart:io` stats never throw (EACCES etc. surface as
  not-found); error branching is centralized in `lib/fs_errors.dart`
  predicates mapping POSIX errno and Win32 codes (ENOENT 2/{2,3},
  EPERM 1/{1314,5,87}, EINVAL 22/{87,4390}, EEXIST 17/{183,80},
  EXDEV 18/{17}).
- **Non-integer config `version`** (e.g. 7.5): TS enters the migration loop
  and fails with CONFIG_MIGRATION_NOT_FOUND; Dart (`is int` check) falls
  through to validation failure. JSON-integer versions behave identically.

## Release/distribution status (M8)

- The Dart CLI is currently distributed **only as raw binaries attached to
  GitHub Releases** (asset names `dotweave-dart-{linux,macos}-{x64,arm64}`,
  `dotweave-dart-win-{x64,arm64}.exe`), built and smoke-tested on 6 native
  runners by the `build-dart` CI job and uploaded by the existing
  `publish-release` job (its `dotweave-*` download pattern already matches
  the `dotweave-dart-*` names, so no separate upload step was needed).
- npm / Homebrew / WinGet / MSIX / Snap continue to package **only the
  TypeScript CLI**, unchanged. The Homebrew formula generator
  (`homebrewArtifactNames` in `tools_dart/lib/src/lib/homebrew.dart`) looks up
  a fixed list of TS asset names, so the extra `dotweave-dart-*` release
  assets do not interfere with it.
- Both CLIs release under the **same `v*.*.*` tag** — one GitHub Release per
  tag carries both sets of binaries.
- This is intentionally a parallel-availability step, not the cutover
  described in the original migration plan's Phase C (which would replace
  the TS `build-pkg`/npm publish path outright). Revisit when the Dart CLI
  is promoted to primary.

# TS → Dart parity decisions

Every intentional behavioral divergence from the pre-cutover TypeScript
implementation (removed from the repo at the Dart cutover) discovered during
the port is recorded here as a historical record, so reviewing the port is a
checklist, not archaeology. Keep entries short: what differs, why, and which
tests pin it.

## Conventions

- Repo paths always use `package:path` `posix` context; local paths use the
  native context — mirrors `node:path.posix` vs `node:path` usage in TS.
- JSON files (`manifest.jsonc`, `settings.jsonc`) must serialize byte-identically
  to `JSON.stringify(config, null, 2)` + trailing newline. Pinned by golden
  tests against TS-generated fixtures (M1).

## Divergences

- **Path removed mid-scan**: the snapshot walkers asserted a stat result was
  non-null for a path the directory listing had just reported. When the path
  disappears in between (an editor rewriting a dotfile during a push), TS and
  the original Dart port both surfaced a raw runtime `TypeError`. The port now
  raises `PATH_DISAPPEARED` with the path and a retry hint. Pinned by
  `test/util/filesystem_test.dart`.
- **Git failure details**: a git command that exits non-zero now raises a
  `DotweaveError` with code `GIT_COMMAND_FAILED` instead of a bare `Exception`.
  The rendered first line is unchanged (stderr, else stdout, else the exec
  message); the only added output is stdout in the rare case git wrote to both
  streams, which the old rethrow discarded.
- **Corrupt committed manifest**: `readCommittedProfileRegistry` reported a
  manifest that is committed but fails to parse as "no committed registry",
  identical to a repository with no HEAD. Parse failures now propagate; only
  git-level failures still mean "absent".

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
- **Portable symlink targets** (repository format 2): TS stored a symlink's
  target verbatim (only `\` -> `/`), so an absolute target committed a
  machine- and user-specific path that pulled as a dangling link elsewhere.
  Dart rewrites an absolute target inside HOME to `~/...` on capture
  (`toPortableLinkTarget`) and expands it against the pulling machine's HOME
  on materialization (`fromPortableLinkTarget`). Prefix matching is lexical
  (no realpath) and case-insensitive on Windows only; a relative target whose
  first segment is literally `~` is stored as `./~/...` so it stays distinct
  from an anchored one. Targets outside HOME stay verbatim and are reported by
  `push`/`status`/`doctor` as non-portable. Pinned by
  `test/util/path_util_test.dart`, `test/config/migrations/repo_format_v2_test.dart`,
  and `test/e2e/symlink_cross_platform_e2e_test.dart`.

## Performance notes (behavior-neutral)

- **Stat fast path** (`lib/src/lib/native_stat.dart`): `getPathStats`,
  `pathExists`, `getFollowedPathStats`, and the rename/remove type
  dispatchers answer plain-file/dir/missing cases with one synchronous
  `GetFileAttributesExW` FFI call on Windows. Reparse points, unusual error
  codes, long paths, and non-Windows platforms delegate to the original
  dart:io implementation kept verbatim, so link/tag semantics are unchanged.
  Pinned by `test/lib/native_stat_test.dart` (field-for-field agreement with
  the dart:io reference, including the CRT mode synthesis for readonly/.exe
  fixtures).
- **Warm-up prefetch** (`_warmArtifactCache` in repo_snapshot.dart,
  `_warmLocalCache` in local_snapshot.dart): a best-effort 64-wide
  read-and-discard pass before each sequential snapshot walk. On Windows the
  first read of a freshly written/cloned file pays a multi-ms filter-driver
  scan; serialized over 10k files this dominated cold push/pull. The walks
  themselves (and thus snapshot insertion order and all error semantics) are
  untouched; the prefetch ignores all failures.
- **Batch hoists**: `writeFileNode` gained `ensureParent` (default true —
  identical behavior); artifact writes precompute the unique parent-dir set
  per batch; pull staging caches `resolveSymbolicLinksSync` per parent
  directory for the process lifetime (TS resolves per file — observable only
  if a parent's symlink chain is swapped mid-pull, which nothing does).
- **`DOTWEAVE_PERF_TRACE=1`** (Dart-only diagnostic): dumps aggregated phase
  timings to stderr from push/pull. Inert without the env var; not part of
  the TS surface.
- Result on the 10k-file benchmark (`tool/benchmark_large_repo.dart`,
  Windows): cold push 89.5s → 13.8s (TS 10.1s), pull 130.3s → 34.5s
  (TS 20.6s), incremental push and status now faster than TS (1.17x/1.42x).

## Cutover status

- The cutover is complete: Dart binaries are built under the original asset
  names (`dotweave-{macos,linux}-{x64,arm64}`, `dotweave-win-{x64,arm64}.exe`)
  and are now **the** distribution, shipped via GitHub Releases, Homebrew,
  WinGet, and MSIX.
- npm distribution of `@tinyrack/dotweave` is discontinued.
- The TypeScript packages have been deleted from the repo. The TS↔Dart compat
  harness served its purpose and was removed along with them (the age interop
  tests remain).

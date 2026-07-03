# Dotweave CLI Behavior Contract

This file tracks the user-visible behaviors that should stay locked by tests.
Prefer one representative e2e test for each high-value workflow, then cover
state combinations in service-level table tests.

| Area | Contract | Primary layer | Current focus |
| --- | --- | --- | --- |
| `init` | Fresh init creates the local repository, manifest, settings, and age identity. Importing an existing repository requires a usable age identity. | e2e + service | Covered; keep wrong-key and missing-git failures explicit. |
| `track` | Tracking only mutates `manifest.jsonc`; repeated tracking preserves unspecified fields and rejects unsafe repo paths. | e2e + service | Covered broadly; add regression tests when new flags are added. |
| `untrack` | Untracking removes manifest entries, and artifact cleanup is reported by `status` and applied by `push`. | e2e + service | Covered for root removals; keep child/parent pruning in service tests. |
| `status` | Status previews both push and pull directions without writing files. | e2e | Covered; lifecycle tests should assert no-write behavior indirectly. |
| `push` | Push mirrors local state into profile namespaces, encrypts secret entries, skips ignored entries, supports dry-run, and is idempotent. | e2e + service | Lifecycle contract covers normal/secret/ignore and dry-run. |
| `pull` | Pull materializes repository artifacts back into `HOME`, decrypts secrets, preserves ignored local paths, supports dry-run, and requires confirmation in non-interactive sessions. | e2e + service | Lifecycle contract covers restoration and dry-run; existing tests cover confirmation. |
| `profile` | Active profile applies to plain `push`, `pull`, `status`, and `doctor`; explicit `--profile` overrides active profile; default entries apply with named profiles. | e2e + service | Existing profile e2e covers pull; add command-specific regressions when profile logic changes. |
| `doctor` | Doctor reports repository, configuration, secret, and local materialization health without treating absent-but-materializable paths as failures. | service + e2e | Covered; use service tests for detailed failure text. |
| `cd` | `cd` launches the configured shell in the sync directory and reports shell failures clearly. | unit + smoke e2e | Covered at command/service level. |
| `skill install` | Skill install validates the skills root, supports dry-run, rejects existing installs without `--force`, and overwrites with `--force`. | CLI e2e + service | CLI contract test covers user-facing output and no-write behavior. |
| `autocomplete` | Scripts remain shell-specific and completion results include the current command surface. | e2e + pty | Covered; add root-command assertions when routes change. |

Regression priority:

1. Data loss risks: pull deletion, type replacement, profile exclusion, ignored paths.
2. Secret handling: encryption at rest, wrong-key failures, identity import.
3. No-write promises: `status`, `push --dry-run`, `pull --dry-run`.
4. Manifest safety: path traversal, reserved suffixes, duplicate/overlapping paths.
5. CLI compatibility: removed flags fail clearly, documented flags parse correctly.

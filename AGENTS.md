# Dotweave

## Project Overview
**Dotweave** is a git-backed configuration synchronization tool for dotfiles. Unlike traditional tools that force you to shape your local environment around a repository, Dotweave treats your home directory (`HOME`) as the source of truth and uses a git repository purely as a synchronization artifact.

- **Main Technologies:** Dart (>=3.12) for the CLI (`packages/cli`), the age encryption implementation (`packages/age`), and internal tooling (`packages/tools`); TypeScript/React with pnpm for the documentation homepage (`homepage/`, a standalone Node project built with React Router and `@tinyrack/docs`). Secrets are age-encrypted.
- **Architecture:** The repo root is a Dart pub workspace (`pubspec.yaml` listing `packages/age`, `packages/cli`, and `packages/tools`); the homepage is an independent Node project at `homepage/` with its own pnpm lockfile. The CLI is distributed as compiled native binaries via GitHub Releases, Homebrew, and WinGet.

---

## Skills
When writing, rewriting, translating, or reviewing public Dotweave documentation under `homepage/app/content`, or documentation-facing copy under `homepage/app/components`, follow `.agents/skills/dotweave-documentation-writing/SKILL.md`. Do not trigger it for release notes, changelogs, contributor README files, Dart source comments, or documentation infrastructure changes without public copy.

---

## Mandatory Validation Loop
You MUST execute a validation loop for every change to ensure system integrity.

For Dart packages (run from `packages/age`, `packages/cli`, and/or `packages/tools`, whichever you changed):
- **Format**: `dart format .`
- **Analyze**: `dart analyze --fatal-infos`
- **Test**: `dart test`

`packages/age` and `packages/cli` tag their Node/PTY-dependent suites, so
`dart test -x interop` is the offline run; the `interop` tests need
`pnpm install` in `packages/age/test/interop` first.

For the homepage (run from `homepage/`):
- **Build**: `pnpm run build`
- **Test**: `pnpm run test`
- **Typecheck**: `pnpm run typecheck`
- **Lint/format**: `pnpm run format:check`

If any step fails, you MUST fix the issues before proceeding or reporting completion.

---

## Workspace Structure
- `packages/cli`: The core CLI tool (Dart, pub workspace member).
- `packages/age`: Pure-Dart age v1 encryption (X25519 recipients), consumed by the CLI through the `dotweave_age` barrel. Kept free of any dotweave type so it stays independently publishable; its wire-format internals are under `lib/src/`.
- `packages/tools`: Internal Dart tooling (release/automation commands via `bin/cli.dart`, pub workspace member).
- `homepage/`: Static React Router documentation and localized landing pages built with `@tinyrack/docs` and `@tinyrack/ui` (standalone pnpm project; reads the CLI version from `packages/cli/pubspec.yaml` at build time).

---

## Building and Running

### CLI Package (`packages/cli`)
- **Fetch Dependencies:** `dart pub get`
- **Run Local CLI:** `dart run bin/dotweave.dart <args>`
- **Run Tests:** `dart test`
- **Analyze:** `dart analyze --fatal-infos`
- **Format:** `dart format .`
- **Native Binary Build:** `dart compile exe bin/dotweave.dart`

### Tools Package (`packages/tools`)
- **Run a Tool Command:** `dart run bin/cli.dart <cmd>`
- **Validate:** `dart format .`, `dart analyze --fatal-infos`, `dart test`

### Homepage (`homepage/`)
- **Install Dependencies:** `pnpm install` (run from `homepage/`)
- **Dev Server:** `pnpm run dev`
- **Build Site:** `pnpm run build`
- **Typecheck:** `pnpm run typecheck`
- **Preview:** `pnpm run preview`

---

## Development Conventions

### General
- **Dart:** Requires Dart SDK 3.12 or higher. Always run `dart format` and keep `dart analyze --fatal-infos` clean before committing.
- **Homepage tooling:** Uses pnpm and strict TypeScript.

### CLI Development
- **Source Structure (under `packages/cli/lib/src/`):**
  - `cli/`: Command definitions and routing. Presentation only — commands render, they do not decide policy.
  - `services/`: Core business logic (git operations, file system, sync logic).
  - `config/`: Configuration schemas and migrations (`config/migrations/`).
  - `terminal/`: Logger, spinner, and colour theme. Presentation; no service may import it.
  - `util/`: Low-level utilities.
- **Layering:** Enforced by `test/architecture_test.dart`, which fails the build on an upward or disallowed import. Change the table there deliberately rather than working around it.
- **Commands:** Follow the existing command-routing style in `lib/src/cli` (root commands are defined in `lib/src/cli/root_commands.dart`). Log via `loggerFor(context)` so output is bound to the run context and stays testable in-process; never call `createCliLogger()` with no arguments from a command.
- **Testing:**
  - Unit/Integration tests: `test/**/*_test.dart`.
  - E2E tests: `test/e2e/`.
  - E2E tests use isolated temporary environments for `HOME` and `XDG_CONFIG_HOME`.
- **Error Handling:** Use the custom error types in `lib/src/util/error.dart`. Set `DOTWEAVE_DEBUG=1` to have `DotweaveError` capture and print the stack trace of its throw site.
- **Parity:** Intentional behavioral divergences from the pre-cutover TypeScript implementation are recorded in `packages/cli/PARITY.md`.

### Documentation / Homepage
- **Localization:** Supports `en`, `ko`, and `ja`. Content is in `app/content/`.
- **UI boundary:** Shared documentation chrome and MDX elements come from `@tinyrack/ui`; product-only globe and terminal composition stay in `app/components/`.

---

## Key Files
- `packages/cli/lib/src/application.dart`: CLI entry point and application building.
- `packages/cli/lib/src/config/sync_schema.dart`: Schema for the sync configuration.
- `packages/cli/PARITY.md`: Recorded divergences from the pre-cutover TypeScript implementation.
- `homepage/docs.config.ts`: Documentation manifest, navigation, localization, redirects, and site metadata.

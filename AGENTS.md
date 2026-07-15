# Dotweave

## Project Overview
**Dotweave** is a git-backed configuration synchronization tool for dotfiles. Unlike traditional tools that force you to shape your local environment around a repository, Dotweave treats your home directory (`HOME`) as the source of truth and uses a git repository purely as a synchronization artifact.

- **Main Technologies:** Node.js (>=24), TypeScript, pnpm (Monorepo), `@stricli/core` (CLI), `zod` (Validation), `age-encryption` (Secrets), `vitest` (Testing), React Router and `@tinyrack/docs` (Homepage/Docs).
- **Architecture:** A monorepo containing a CLI package (`@tinyrack/dotweave`) and a documentation homepage (`@tinyrack/dotweave-homepage`).

---

## Mandatory Validation Loop
You MUST execute a validation loop for every change to ensure system integrity.
- **Build**: `pnpm run build`
- **Test**: `pnpm run test`
- **Lint/Format (biome)**: `pnpm run format` and `pnpm run format:check`

If any step fails, you MUST fix the issues before proceeding or reporting completion. Specifically for the CLI package, you can use `pnpm --filter @tinyrack/dotweave check` for a comprehensive check.

---

## Workspace Structure
Managed via `pnpm` workspaces:
- `packages/cli`: The core CLI tool.
- `packages/homepage`: Static React Router documentation and localized landing pages built with `@tinyrack/docs` and `@tinyrack/ui`.

---

## Building and Running

### Root Commands
- **Install Dependencies:** `pnpm install`
- **Build All:** `pnpm run build`
- **Run All Dev:** `pnpm run dev`
- **Format Code:** `pnpm run format`

### CLI Package (`packages/cli`)
- **Development (Watch):** `pnpm --filter @tinyrack/dotweave dev`
- **Build:** `pnpm --filter @tinyrack/dotweave build`
- **Typecheck:** `pnpm --filter @tinyrack/dotweave typecheck`
- **Run Tests:** `pnpm --filter @tinyrack/dotweave test`
- **Full Check (Typecheck + Lint + Test):** `pnpm --filter @tinyrack/dotweave check`
- **Run Local CLI:** `node packages/cli/bin/index.js` or `pnpm --filter @tinyrack/dotweave start`
- **Executable Build:** `pnpm --filter @tinyrack/dotweave pkg:build`

### Homepage Package (`packages/homepage`)
- **Dev Server:** `pnpm --filter @tinyrack/dotweave-homepage dev`
- **Build Site:** `pnpm --filter @tinyrack/dotweave-homepage build`
- **Typecheck:** `pnpm --filter @tinyrack/dotweave-homepage typecheck`
- **Preview:** `pnpm --filter @tinyrack/dotweave-homepage preview`

---

## Development Conventions

### General
- **Tooling:** Use `biome` for linting and formatting. Always run `pnpm run format` before committing.
- **Node.js:** Requires Node.js 24 or higher.
- **Strict TypeScript:** `tsconfig.json` is configured with strict settings.

### CLI Development
- **Source Structure:**
  - `src/cli/`: Command definitions and routing.
  - `src/services/`: Core business logic (git operations, file system, sync logic).
  - `src/config/`: Configuration schemas (Zod) and migrations.
  - `src/lib/`: Low-level utilities.
- **Import Aliases:** Use `#app/*` for all internal CLI imports (mapped to `src/*`).
- **Commands:** Commands are built using `@stricli/core`. Root commands are defined in `src/cli/root-commands.ts`.
- **Testing:**
  - Unit/Integration tests: `src/**/*.test.ts`.
  - E2E tests: `tests/**/*.e2e.test.ts`.
  - E2E tests use isolated temporary environments for `HOME` and `XDG_CONFIG_HOME`.
- **Error Handling:** Use the custom error types in `src/lib/error.ts`.

### Documentation / Homepage
- **Localization:** Supports `en`, `ko`, and `ja`. Content is in `app/content/`.
- **UI boundary:** Shared documentation chrome and MDX elements come from `@tinyrack/ui`; product-only globe and terminal composition stay in `app/components/`.

---

## Key Files
- `pnpm-workspace.yaml`: Monorepo configuration.
- `biome.json`: Linting and formatting rules.
- `packages/cli/src/application.ts`: CLI entry point and application building.
- `packages/cli/src/config/sync-schema.ts`: Zod schema for the sync configuration.
- `packages/homepage/docs.config.ts`: Documentation manifest, navigation, localization, redirects, and site metadata.

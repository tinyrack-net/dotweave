---
name: dotweave-documentation-writing
description: Write, rewrite, translate, and review Dotweave public documentation in natural English, Korean, and Japanese. Use for prose, examples, and documentation-facing copy under homepage/app/content or homepage/app/components, including overview, concept, guide, command reference, and configuration reference pages. Do not use for release notes, changelogs, contributor README files, Dart source-code comments, or documentation infrastructure changes without public copy.
---

# Dotweave Documentation Writing

Keep public documentation accurate, useful, locally natural, and aligned across
English, Korean, and Japanese. Preserve the repository's existing content
contracts instead of introducing a second documentation system.

## Establish the Facts

- Read the Dart implementation in `packages/cli` before writing. The CLI source
  is the only authority for commands, flags, defaults, file layout, and error
  codes. Do not use existing prose, CLI help text, or a previous revision of a
  page as the source of truth.
- Command and flag facts live in `packages/cli/lib/src/cli/**`. Config field
  facts live in `packages/cli/lib/src/config/sync_schema.dart`,
  `config/global_config.dart`, and `config/constants.dart`. Path resolution
  lives in `config/xdg.dart` and `config/platform.dart`. Repository layout lives
  in `services/repo_artifacts.dart` and `services/repository_ignore.dart`. Error
  codes and their rendered format live in `lib/src/lib/error.dart`.
- Identify the reader's goal and the facts needed to complete it: purpose,
  prerequisites, the exact command, defaults, choices, platform differences,
  limitations, and expected result.
- State conditions and guarantees precisely. Do not guess behavior or use
  absolute claims such as "always," "fully," or "automatically" unless the
  implementation guarantees them.
- Where the CLI's own help text is inaccurate, document the real behavior. Do
  not repeat a help string you have not verified against the implementation.
- Do not document a command, flag, or hint that the CLI does not register.
- Preserve valid frontmatter, page slugs, code identifiers, `aria-label` values,
  and structural contracts unless the task explicitly changes them.

## Write for the Reader

- Lead with what the reader can accomplish, then explain when to choose an
  option and why.
- Keep one main idea per paragraph. Prefer short, direct sentences and concrete
  nouns over vague references such as "this," "the above," or "the relevant
  item."
- Explain decisions, outcomes, and caveats instead of narrating output line by
  line.
- Avoid hype, filler, unsupported judgments, emoticons, and decorative emoji.
- Avoid first person when the sentence works without it. In Korean, use `저`
  only when first person is unavoidable; do not use `나` or `필자`. Avoid
  `우리` and `저희` unless an explicit organizational voice requires them.

## Use Natural Korean Haeyoche

Apply these rules to Korean explanatory prose, including frontmatter
descriptions. Headings, labels, code, identifiers, quotations, and intentionally
reproduced terminal output do not need an artificial sentence ending.

- Use neutral conversational haeyoche such as `~이에요`, `~예요`, `~해요`,
  `~할 수 있어요`, `~하세요`, and `~해 보세요`.
- Do not use formal hasipsioche endings such as `~입니다`, `~합니다`, or
  `~하십시오`.
- Do not use note-style endings such as `~함` or `~했음`.
- Avoid author-intention endings such as `~할게요` and `~해볼게요` in
  instructional prose. Direct the reader with `~하세요` or state the behavior
  with `~해요` instead.
- Keep the tone calm and professional. Avoid overly casual expressions such as
  `쉽죠`, `간단하거든요`, or `엄청`.
- Omit repeated subjects naturally. Do not repeatedly address the reader as
  `여러분` or refer to them abstractly as `사용자` when a direct instruction is
  clearer.
- Attach particles directly to inline code with no space: `` `manifest.jsonc`를 ``,
  `` `--dry-run`으로 ``.

Examples:

- `이 명령은 저장소를 초기화합니다.` -> `이 명령은 저장소를 초기화해요.`
- `이제 파일을 추적해볼게요.` -> `` `dotweave track`으로 파일을 추적하세요. ``
- `아래와 같이 진행합니다.` -> `` `dotweave status`를 먼저 실행하세요. ``

This rule is machine-enforced. `homepage/tests/content-style.test.ts` fails on
any `니다` or `십시오` occurrence under `homepage/app/content/ko`.

## Localize Meaning, Not Sentence Shape

- Keep behavior, constraints, commands, and user outcomes equivalent across
  locales. Do not force translations to have the same sentence count or word
  order.
- Write English with concise active voice and direct instructions. Prefer
  `Use ...` over `It is recommended that you use ...`.
- Write Japanese explanatory prose in consistent `です・ます調`. Use natural
  instructions such as `〜してください`, and prefer concise forms such as
  `〜できます` over unnecessary `〜することができます`. Put a half-width space
  around Latin runs and inline code: `` `--profile` を指定します ``.
- Preserve command names, flag names, file names, config field names,
  environment variable names, error codes, and `aria-label` values. Localize
  headings, frontmatter copy, prose, and user-visible example text when
  appropriate.
- Terminal output shown in a code fence is reproduced, not translated. The CLI
  emits English only.
- Use one term consistently for one concept within and across pages. Prefer a
  locally established technical term over a literal translation; preserve the
  English identifier in code formatting when ambiguity remains.
- After translating, reread each localized page independently without matching
  it sentence by sentence against the source. Remove unnatural source-language
  order, repeated pronouns, and mixed-language phrasing.

## Terminology

| Concept | en | ko | ja |
| --- | --- | --- | --- |
| the git-backed mirror directory | sync directory | sync 디렉터리 | 同期ディレクトリ |
| `<dotweaveHome>` | dotweave home directory | dotweave 홈 디렉터리 | dotweave ホームディレクトリ |
| the app-data root | app-data directory | 앱 데이터 디렉터리 | アプリデータディレクトリ |
| a manifest record | tracked entry | 추적 항목 | トラッキング項目 |
| a file written into the repository | artifact | artifact | artifact |
| `mode` value | sync mode | 동기화 모드 | 同期モード |
| `profiles` member | profile | 프로필 | プロファイル |
| age public key | recipient | recipient | recipient |
| age private key | identity | identity | identity |
| `manifest.jsonc` | manifest | manifest | manifest |
| `dotweave push` direction | push | push | push |
| `dotweave pull` direction | pull | pull | pull |

- Keep `artifact`, `recipient`, `identity`, `manifest`, `push`, `pull`, `age`,
  `git`, and every flag name in Latin script in all three locales.
- Korean: do not translate `artifact` as `산출물` or `identity` as `신원`. Use
  `디렉터리`, not `디렉토리`.
- Japanese: prefer `同期ディレクトリ` over `シンクディレクトリ`.

## Match the Document Type

Read `homepage/tests/content-style.test.ts`,
`homepage/tests/content-contract.test.ts`, `homepage/docs.config.ts`, and a
neighboring page before changing document structure.

Every page uses `##` headings only. Do not use `###`. Do not use an `#` heading;
the page title comes from frontmatter. Aim for four to nine `##` headings.

The `##` heading count and order must match across `en`, `ko`, and `ja` for the
same page. The heading text is localized; the structure is not.

Every page ends with a forward-link paragraph offering two next steps, or with a
grouped list of related-page links.

**Splash page** (`index.mdx` only): frontmatter with `layout: splash` and
`navigation: false`, then a single `<DotweaveHome>` element. No headings, no
prose.

**Step guide** (install, first sync, second device, daily workflow, shell
autocomplete, agent skill): open with a two-to-three sentence lede that states
the outcome, the scope of the guide, and the prerequisites. Number every step
heading as `## 1. Verb object`, and close with a single unnumbered verification
heading: `## Check the result` / `## 결과 확인` / `## 結果を確認する`. One step
does one thing and ends in a copy-ready command.

**Concept page** (how syncing works, repository layout, sync modes, profiles,
platform paths, secrets): open with no lede. The first `##` is the thesis, and
the paragraph beneath it is the argument. Use imperative or noun-phrase
headings. Close with `## Implementation and reference` /
`## 구현과 참고` / `## 実装とリファレンス`. State non-goals in their own
paragraph rather than implying them.

**Command reference page** (`reference/*`): use this skeleton, omitting
`## Arguments` or `## Flags` when the command takes none.

```
## Synopsis
## Arguments
## Flags
## Behavior
## Errors
## Related commands
```

Localized headings: `## 사용법` / `## 引数` etc. — match the neighboring page
rather than inventing a new label. `## Flags` tables use three columns:
`| Flag | Type and default | Purpose |` (ko `| 플래그 | 타입과 기본값 | 역할 |`,
ja `| フラグ | 型と既定値 | 用途 |`). Subcommand-only commands (`profile`,
`autocomplete`, `skill`) replace `## Arguments`/`## Flags`/`## Behavior` with
one `##` per subcommand.

**Configuration reference page** (`config/*`): the only place a config field
name appears with its type and default in a table. Include exactly one
`## Example` code fence per page, and no `dotweave` invocation outside it. Do
not put task steps on a configuration page. Link forward to the guide that
changes the field.

Do not add empty sections merely to satisfy a template.

## Avoid Duplicating Facts

The documentation is one system, not a set of independent pages.

- A config field's type and default appear only under `config/`. Concept and
  guide pages name the field in prose and link to the configuration page.
- An error code is explained only in `config/errors.mdx`. Other pages name the
  code and link to its area anchor, for example
  `[TARGET_CONFLICT](/en/config/errors/#tracking-targets)`.
- A concept is explained once. A guide that needs the concept links to it
  instead of restating it.
- When you find the same fact stated in two places, delete one and link.

## Keep Examples Trustworthy

- Every command must run as written against the current CLI. Verify flag names
  and defaults with `dart run bin/dotweave.dart <command> --help` from
  `packages/cli`, then confirm the behavior in the source.
- Keep examples minimal but complete and copy-ready. Avoid combining unrelated
  concepts in one example.
- Every code fence carries a language tag: `bash`, `powershell`, `fish`, `json`,
  or `jsonc`. Do not omit it.
- Do not use ellipses, placeholders such as `...`, or invented output. Show real
  output or show none.
- Use angle-bracket placeholders for values the reader supplies:
  `<your-repo-url>`, `<profile>`.
- Explain destructive behavior before showing the command. `dotweave init
  --force` deletes the age identity; `dotweave untrack` deletes repository
  artifacts.

## Use Only the Approved Components

Import each component explicitly in every file that uses it. Leave two blank
lines after the import block.

```tsx
import { TRAlert } from "@tinyrack/ui/components/alert";
import { TRSteps } from "@tinyrack/ui/components/steps";
import { TRTabs } from "@tinyrack/ui/components/tabs";
import { TRFileTree } from "@tinyrack/ui/components/file-tree";
```

- `TRAlert.Root` with `variant` of `success`, `info`, `warning`, or `neutral`.
  Use an alert for a consequence the reader must not miss, not for emphasis.
- `TRSteps.Root` and `TRSteps.Item` for a sequence inside one `##` section.
- `TRTabs` compound API for per-platform alternatives.
- `TRFileTree` for a directory tree. Keep existing `aria-label` values verbatim;
  `homepage/tests/browser.test.ts` asserts them per locale.
- `DotweaveHome` is available only in `index.mdx`.
- Do not use bare `<Aside>`, `<Steps>`, `<Tabs>`, `<TabItem>`, or `<FileTree>`,
  and do not import from `@astrojs/`. `content-contract.test.ts` rejects them.
- Write MDX tags flush left with blank lines around block children.

Internal links are locale-prefixed, absolute, and trailing-slashed:
`[Sync modes](/en/concepts/sync-modes/)`. Every link must resolve to a real
route; `content-contract.test.ts` checks this.

## Verify Proportionately

- Review the diff for factual accuracy, natural language, terminology, and
  locale parity.
- Confirm matching `##` structure, commands, flags, and documented facts across
  English, Korean, and Japanese.
- Run the homepage checks from `homepage/`:

```bash
pnpm run test
pnpm run typecheck
pnpm run format:check
pnpm run build
```

- Run `pnpm run test:audit` after `pnpm run build` when a page's headings,
  file-tree labels, or landing copy changed.
- Adding or removing a page changes the hardcoded page counts in
  `content-contract.test.ts` and the `navigation` array in `docs.config.ts`.
  `loadDocsManifest` fails when `navigation` names a page that does not exist,
  so land both in the same change.
- Run `git diff --check` before handoff. Report the checks selected and any
  remaining language-review uncertainty.

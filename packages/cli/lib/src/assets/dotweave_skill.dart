// The embedded SKILL.md asset content installed by `dotweave skill install`.
// The YAML front matter `name: dotweave` is pinned by tests.

const String dotweaveSkillContent = r'''---
name: dotweave
description: Use when operating or developing the Dotweave CLI for git-backed dotfile synchronization.
---

# Dotweave

Dotweave is a git-backed configuration synchronization tool for dotfiles. It treats `HOME` as the source of truth and uses a git repository as the synchronization artifact.

## Safe CLI Use

- Run `dotweave status` before any sync so you understand pending local, repository, and conflict changes.
- Remember the direction: `dotweave push` copies tracked changes from `HOME` into the sync repository; `dotweave pull` applies repository state back into `HOME`.
- Use `dotweave track <path>` only for files or directories that should be managed by Dotweave, and `dotweave untrack <path>` when a path should stop syncing.
- Check the active profile before changing configuration. Profiles let different machines or environments sync different path sets.
- Be careful with secrets. Age-encrypted entries should stay encrypted in the repository, identity files are sensitive, and plaintext secret material should not be committed accidentally.
- For tests or automation, isolate `HOME` and `XDG_CONFIG_HOME` so Dotweave never touches the operator's real dotfiles.

## Development Commands

- Use `dart test` (from `packages/cli`) to run CLI tests.
- Use `dart analyze --fatal-infos` and `dart format .` to validate and format the code.
- Use `dart run bin/dotweave.dart <args>` to run the CLI locally.
- Use `dart compile exe bin/dotweave.dart` to build a native binary.

## Development Guidance

- Add failing tests before implementing behavioral changes.
- Keep CLI command modules thin and put filesystem or sync behavior in `lib/src/services`.
- Preserve the existing command-routing style in `lib/src/cli`.
- Use `DotweaveError` for user-facing failures.
- Run formatting and validation before reporting completion.
''';

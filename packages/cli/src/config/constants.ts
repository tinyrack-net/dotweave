const APP_NAME = "dotweave";
const AUTOCOMPLETE_COMPLETE_SUBCOMMAND = "__complete";

export const AppConstants = {
  APP: {
    NAME: APP_NAME,
  },
  AUTOCOMPLETE: {
    CLI_COMMAND_NAME: APP_NAME,
    COMMAND: `${APP_NAME} ${AUTOCOMPLETE_COMPLETE_SUBCOMMAND}`,
    COMPLETE_SUBCOMMAND: AUTOCOMPLETE_COMPLETE_SUBCOMMAND,
  },
  GLOBAL_CONFIG: {
    CURRENT_VERSION: 3,
    FILE_NAME: "settings.jsonc",
  },
  INIT: {
    DEFAULT_IDENTITY_FILE_NAME: "keys.txt",
    LEGACY_IDENTITY_FILE: `~/.config/${APP_NAME}/age/keys.txt`,
  },
  SYNC: {
    CONFIG_FILE_NAME: "manifest.jsonc",
    CONFIG_VERSION: 8,
    DEFAULT_CONCURRENCY: 20,
    DEFAULT_PROFILE: "default",
    MODES: ["normal", "secret", "ignore"],
    SECRET_ARTIFACT_SUFFIX: ".dotweave.secret",
    SYMLINK_ARTIFACT_SUFFIX: ".dotweave.symlink",
    // On-disk repository artifact format version. Independent of CONFIG_VERSION
    // (which versions the manifest structure); this versions how artifacts are
    // laid out under profiles/. Format 1 stores symlinks as .dotweave.symlink
    // metadata files (format 0 used physical symlinks/junctions).
    REPOSITORY_FORMAT: 1,
    // Repositories below this format are refused with guidance to migrate using
    // an older dotweave first. Raise this (and delete the corresponding
    // migration + legacy-read code) once a format is safe to drop.
    MIN_SUPPORTED_REPOSITORY_FORMAT: 0,
  },
  XDG: {
    APP_DIRECTORY_NAME: APP_NAME,
    SYNC_DIRECTORY_NAME: "repository",
  },
} as const;

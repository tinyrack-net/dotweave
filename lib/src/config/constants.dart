const String _appName = 'dotweave';
const String _autocompleteCompleteSubcommand = '__complete';

/// Mirror of `config/constants.ts` `AppConstants`. The TS side is a nested
/// const object; Dart uses nested classes with const singletons so call sites
/// read identically: `AppConstants.sync.configFileName`.
class AppConstants {
  static const app = _AppSection();
  static const autocomplete = _AutocompleteSection();
  static const globalConfig = _GlobalConfigSection();
  static const init = _InitSection();
  static const sync = _SyncSection();
  static const xdg = _XdgSection();
}

class _AppSection {
  const _AppSection();

  final String name = _appName;
}

class _AutocompleteSection {
  const _AutocompleteSection();

  final String cliCommandName = _appName;
  final String command = '$_appName $_autocompleteCompleteSubcommand';
  final String completeSubcommand = _autocompleteCompleteSubcommand;
}

class _GlobalConfigSection {
  const _GlobalConfigSection();

  final int currentVersion = 3;
  final String fileName = 'settings.jsonc';
}

class _InitSection {
  const _InitSection();

  final String defaultIdentityFileName = 'keys.txt';
  final String legacyIdentityFile = '~/.config/$_appName/age/keys.txt';
}

class _SyncSection {
  const _SyncSection();

  final String configFileName = 'manifest.jsonc';
  final int configVersion = 8;
  final int defaultConcurrency = 20;
  final String defaultProfile = 'default';
  final List<String> modes = const ['normal', 'secret', 'ignore'];
  final String secretArtifactSuffix = '.dotweave.secret';
  final String symlinkArtifactSuffix = '.dotweave.symlink';

  /// On-disk repository artifact format version. Independent of
  /// [configVersion] (which versions the manifest structure); this versions
  /// how artifacts are laid out under profiles/. Format 1 stores symlinks as
  /// .dotweave.symlink metadata files (format 0 used physical
  /// symlinks/junctions). Format 2 additionally stores a symlink target that
  /// points inside HOME as `~/...`, so it resolves against the pulling
  /// machine's home directory instead of the pushing machine's.
  final int repositoryFormat = 2;

  /// Repositories below this format are refused with guidance to migrate
  /// using an older dotweave first. Raise this (and delete the corresponding
  /// migration + legacy-read code) once a format is safe to drop.
  final int minSupportedRepositoryFormat = 0;
}

class _XdgSection {
  const _XdgSection();

  final String appDirectoryName = _appName;
  final String syncDirectoryName = 'repository';
}

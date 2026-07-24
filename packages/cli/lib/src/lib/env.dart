// ignore_for_file: non_constant_identifier_names

import 'dart:io';

/// Validated view over the process environment, mirroring the shape of the
/// Zod-backed `Env` type in the TS module. Environment values are always
/// optional strings; unknown keys remain accessible via [operator []]
/// (the TS schema's catchall).
class Env {
  Env(Map<String, String> environment, {bool? caseInsensitiveKeys})
    : _environment = Map<String, String>.unmodifiable(environment),
      _caseInsensitiveKeys = caseInsensitiveKeys ?? Platform.isWindows;

  final Map<String, String> _environment;
  final bool _caseInsensitiveKeys;

  /// Looks up an arbitrary environment variable. On Windows, environment
  /// variable names are case-insensitive (Node normalizes lookups on
  /// `process.env`), so the lookup falls back to a case-insensitive scan.
  String? operator [](String key) {
    final direct = _environment[key];
    if (direct != null) {
      return direct;
    }
    if (!_caseInsensitiveKeys) {
      return null;
    }
    final upperKey = key.toUpperCase();
    for (final entry in _environment.entries) {
      if (entry.key.toUpperCase() == upperKey) {
        return entry.value;
      }
    }
    return null;
  }

  /// Windows roaming application data directory. Used as the default dotweave
  /// app-data parent on Windows, producing `%APPDATA%\dotweave`.
  String? get APPDATA => this['APPDATA'];

  /// Windows only. Path to the default command interpreter (usually
  /// `cmd.exe`). Used as the fallback shell command when no explicit override
  /// is configured and no parent PowerShell process is detected on the
  /// Windows platform.
  String? get COMSPEC => this['COMSPEC'];

  /// Dotweave-specific app-data root override. When set, this replaces the
  /// platform default root that contains `settings.jsonc`, `repository`, and
  /// identity key material.
  String? get DOTWEAVE_HOME => this['DOTWEAVE_HOME'];

  /// The current user's home directory. Used as the root for resolving
  /// `~`-prefixed local paths throughout config loading, path expansion, and
  /// sync entry resolution on all platforms.
  String? get HOME => this['HOME'];

  /// Windows local application data directory. Used as the Windows fallback
  /// when `APPDATA` is not set.
  String? get LOCALAPPDATA => this['LOCALAPPDATA'];

  /// Unix/macOS/WSL. Absolute path to the user's preferred login shell (e.g.
  /// `/bin/zsh` or `/usr/bin/fish`). Read by the `dotweave cd` command to
  /// select the shell to launch when no explicit override is configured.
  String? get SHELL => this['SHELL'];

  /// Windows user profile directory. Used as the final Windows fallback for
  /// `%USERPROFILE%\AppData\Roaming\dotweave` when AppData variables are
  /// unset.
  String? get USERPROFILE => this['USERPROFILE'];

  /// WSL (Windows Subsystem for Linux) only. Set by WSL to the name of the
  /// active distro (e.g. `Ubuntu`). Its presence is used to detect the WSL
  /// platform so that WSL-specific sync mode overrides are applied when
  /// resolving config entries.
  String? get WSL_DISTRO_NAME => this['WSL_DISTRO_NAME'];

  /// WSL (Windows Subsystem for Linux) only. Path to the WSL interop socket
  /// used to communicate with the Windows host. Its presence is used as a
  /// secondary signal for detecting the WSL platform alongside
  /// `WSL_DISTRO_NAME`.
  String? get WSL_INTEROP => this['WSL_INTEROP'];

  /// XDG Base Directory spec override for the user's config home. When set,
  /// replaces the default `~/.config` location for all dotweave configuration
  /// files (global config, identity keys, the sync directory). Expanded via
  /// Windows-style `%VARIABLE%` expansion when running under WSL or Windows.
  String? get XDG_CONFIG_HOME => this['XDG_CONFIG_HOME'];
}

final Env ENV = Env(Platform.environment);

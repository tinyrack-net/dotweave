// Dart port of `packages/cli/src/services/terminal/path-completion.ts`.
//
// The TS function is a stricli completion callback bound to an
// `ApplicationContext` receiver; the context is unused, so the Dart port is a
// plain function. The optional [cwd]/[homedir] overrides are the DI seams
// replacing the `process.cwd` and `os.homedir` test mocks.

import 'dart:io';

import 'package:dotweave/src/lib/collation.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/fs_errors.dart';
import 'package:path/path.dart' as p;

const String _homePrefix = '~';
const String _hiddenEntryPrefix = '.';
const String _shellPathSeparator = '/';

typedef _CompletionBase = ({
  String absoluteDirectory,
  String displayPrefix,
  String entryPrefix,
});

/// Mirrors node:path `resolve` using the platform-native path context:
/// absolute (or Windows root-relative) parts restart resolution and the
/// result is normalized.
String _resolvePath(List<String> paths) {
  return p.normalize(p.joinAll(paths));
}

/// Mirrors node:os `homedir()` for the platforms dotweave supports.
String _osHomedir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? '';
  }
  return Platform.environment['HOME'] ?? '';
}

/// Mirrors node `process.cwd()`.
String _processCwd() {
  return Directory.current.path;
}

/// The TS list is `EACCES`, `ENOENT`, `ENOTDIR`; the Dart predicates map the
/// same conditions onto POSIX errno and Win32 error codes.
bool _isRecoverableCompletionError(Object error) {
  return isPermissionDenied(error) ||
      isNotFound(error) ||
      isNotADirectory(error);
}

_CompletionBase _buildRelativeCompletionBase(
  String partial,
  String Function() cwd,
) {
  final lastSeparatorIndex = partial.lastIndexOf(_shellPathSeparator);
  final displayPrefix = lastSeparatorIndex < 0
      ? ''
      : partial.substring(0, lastSeparatorIndex + 1);
  final entryPrefix = lastSeparatorIndex < 0
      ? partial
      : partial.substring(lastSeparatorIndex + 1);

  return (
    absoluteDirectory: _resolvePath([
      cwd(),
      displayPrefix == '' ? '.' : displayPrefix,
    ]),
    displayPrefix: displayPrefix,
    entryPrefix: entryPrefix,
  );
}

_CompletionBase _buildAbsoluteCompletionBase(
  String partial,
  String Function() cwd,
) {
  final lastSeparatorIndex = partial.lastIndexOf(_shellPathSeparator);
  final displayPrefix = lastSeparatorIndex < 0
      ? _shellPathSeparator
      : partial.substring(0, lastSeparatorIndex + 1);
  final entryPrefix = lastSeparatorIndex < 0
      ? partial
      : partial.substring(lastSeparatorIndex + 1);

  return (
    absoluteDirectory: _resolvePath([cwd(), displayPrefix]),
    displayPrefix: displayPrefix,
    entryPrefix: entryPrefix,
  );
}

_CompletionBase? _buildHomeCompletionBase(
  String partial,
  String Function() homedir,
) {
  if (partial == _homePrefix) {
    return (
      absoluteDirectory: homedir(),
      displayPrefix: '$_homePrefix$_shellPathSeparator',
      entryPrefix: '',
    );
  }

  if (!partial.startsWith('$_homePrefix$_shellPathSeparator')) {
    return null;
  }

  final homeRelativePath = partial.substring(2);
  final lastSeparatorIndex = homeRelativePath.lastIndexOf(_shellPathSeparator);
  final directorySuffix = lastSeparatorIndex < 0
      ? ''
      : homeRelativePath.substring(0, lastSeparatorIndex + 1);
  final entryPrefix = lastSeparatorIndex < 0
      ? homeRelativePath
      : homeRelativePath.substring(lastSeparatorIndex + 1);

  return (
    absoluteDirectory: _resolvePath([
      homedir(),
      directorySuffix == '' ? '.' : directorySuffix,
    ]),
    displayPrefix: '$_homePrefix$_shellPathSeparator$directorySuffix',
    entryPrefix: entryPrefix,
  );
}

_CompletionBase? _resolveCompletionBase(
  String partial,
  String Function() cwd,
  String Function() homedir,
) {
  if (partial.startsWith(_homePrefix)) {
    return _buildHomeCompletionBase(partial, homedir);
  }

  if (partial.startsWith(_shellPathSeparator)) {
    return _buildAbsoluteCompletionBase(partial, cwd);
  }

  return _buildRelativeCompletionBase(partial, cwd);
}

bool _shouldIncludeEntry(String name, String entryPrefix) {
  if (!name.startsWith(entryPrefix)) {
    return false;
  }

  if (!entryPrefix.startsWith(_hiddenEntryPrefix) &&
      name.startsWith(_hiddenEntryPrefix)) {
    return false;
  }

  return true;
}

String _buildCompletionValue(
  _CompletionBase base,
  String entryName,
  bool isDirectory,
) {
  final completion = '${base.displayPrefix}$entryName';

  return isDirectory ? '$completion$_shellPathSeparator' : completion;
}

Future<List<String>> proposePathCompletions(
  String partial, {
  String Function()? cwd,
  String Function()? homedir,
}) async {
  final base = _resolveCompletionBase(
    partial,
    cwd ?? _processCwd,
    homedir ?? _osHomedir,
  );

  if (base == null) {
    return [];
  }

  try {
    final entries = await listDirectoryEntries(base.absoluteDirectory);

    return entries
        .where((entry) => _shouldIncludeEntry(entry.name, base.entryPrefix))
        .map((entry) {
          return _buildCompletionValue(base, entry.name, entry.isDirectory);
        })
        .toList()
      ..sort(compareLocaleLike);
  } catch (error) {
    if (_isRecoverableCompletionError(error)) {
      return [];
    }

    rethrow;
  }
}

import 'dart:io';

// Dart has no octal integer literals; these hex constants mirror the octal
// modes used by the TypeScript source.
const int _mode0o755 = 0x1ED; // 0o755
const int _mode0o644 = 0x1A4; // 0o644
const int _mask0o777 = 0x1FF; // 0o777
const int _mask0o444 = 0x124; // 0o444
const int _mask0o111 = 0x49; // 0o111

/// Indicates whether the current filesystem can reliably round-trip POSIX
/// modes.
bool supportsPosixFileModes() {
  return !Platform.isWindows;
}

/// Builds the default file mode for regular sync artifacts.
int buildExecutableMode(bool executable) {
  return executable ? _mode0o755 : _mode0o644;
}

/// Expands directory permissions so readable entries remain searchable.
int buildSearchableDirectoryMode(int mode) {
  final normalizedMode = mode & _mask0o777;

  return normalizedMode | ((normalizedMode & _mask0o444) >> 2);
}

/// Determines whether a mode grants execute permission to any class.
bool isExecutableMode(int mode) {
  return (mode & _mask0o111) != 0;
}

final RegExp _permissionOctalPattern = RegExp(r'^0[0-7]{3}$');

/// Validates permission strings accepted by dotweave configuration.
bool isPermissionOctal(String value) {
  return _permissionOctalPattern.hasMatch(value);
}

/// Converts a validated permission string into a numeric file mode.
int parsePermissionOctal(String value) {
  if (!isPermissionOctal(value)) {
    throw Exception(
      'Invalid permission octal: $value. '
      'Expected a 4-character octal string like "0600" or "0755".',
    );
  }

  return int.parse(value, radix: 8);
}

/// Formats a mode as the permission string shape used in configuration.
String formatPermissionOctal(int mode) {
  return '0${(mode & _mask0o777).toRadixString(8).padLeft(3, '0')}';
}

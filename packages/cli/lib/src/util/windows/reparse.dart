/// Pure (FFI-free) encoding and decoding of the Windows
/// `REPARSE_DATA_BUFFER` structure used by `FSCTL_SET_REPARSE_POINT` and
/// `FSCTL_GET_REPARSE_POINT` for junctions (mount points) and symlinks.
///
/// Layout reference (all fields little-endian):
///
/// ```text
/// ULONG  ReparseTag
/// USHORT ReparseDataLength
/// USHORT Reserved
/// USHORT SubstituteNameOffset   // relative to PathBuffer, in bytes
/// USHORT SubstituteNameLength   // bytes, excluding NUL terminator
/// USHORT PrintNameOffset
/// USHORT PrintNameLength
/// ULONG  Flags                  // symlink reparse points only
/// WCHAR  PathBuffer[]
/// ```
library;

import 'dart:typed_data';

/// `IO_REPARSE_TAG_MOUNT_POINT` — junctions and volume mount points.
const int ioReparseTagMountPoint = 0xA0000003;

/// `IO_REPARSE_TAG_SYMLINK` — NTFS symbolic links.
const int ioReparseTagSymlink = 0xA000000C;

/// `SYMLINK_FLAG_RELATIVE` — the symlink substitute name is a path relative
/// to the directory containing the link.
const int symlinkFlagRelative = 0x1;

/// `MAXIMUM_REPARSE_DATA_BUFFER_SIZE`.
const int maximumReparseDataBufferSize = 16 * 1024;

const int _headerSize = 8;
const int _mountPointDataHeaderSize = 8;
const int _symlinkDataHeaderSize = 12;

/// Decoded contents of a name-carrying reparse point.
class ReparsePointData {
  const ReparsePointData({
    required this.tag,
    required this.substituteName,
    required this.printName,
    this.flags = 0,
  });

  /// The reparse tag (for example [ioReparseTagMountPoint]).
  final int tag;

  /// The kernel-facing target, typically NT-prefixed (`\??\C:\...`) for
  /// absolute targets and verbatim for relative symlink targets.
  final String substituteName;

  /// The user-facing target without NT prefixes.
  final String printName;

  /// Symlink-only flags ([symlinkFlagRelative]); always `0` for junctions.
  final int flags;

  bool get isMountPoint => tag == ioReparseTagMountPoint;

  bool get isSymlink => tag == ioReparseTagSymlink;

  bool get isRelative => isSymlink && (flags & symlinkFlagRelative) != 0;
}

/// Encodes a mount-point (junction) `REPARSE_DATA_BUFFER` carrying
/// [substituteName] (the `\??\`-prefixed absolute target) and [printName].
Uint8List encodeMountPointReparseData(String substituteName, String printName) {
  final substituteUnits = substituteName.codeUnits;
  final printUnits = printName.codeUnits;
  final substituteBytes = substituteUnits.length * 2;
  final printBytes = printUnits.length * 2;

  // Each name is NUL-terminated inside PathBuffer; the lengths exclude the
  // terminators.
  final pathBufferBytes = substituteBytes + 2 + printBytes + 2;
  final reparseDataLength = _mountPointDataHeaderSize + pathBufferBytes;
  final buffer = Uint8List(_headerSize + reparseDataLength);
  final view = ByteData.view(buffer.buffer);

  view.setUint32(0, ioReparseTagMountPoint, Endian.little);
  view.setUint16(4, reparseDataLength, Endian.little);
  view.setUint16(6, 0, Endian.little);
  view.setUint16(8, 0, Endian.little);
  view.setUint16(10, substituteBytes, Endian.little);
  view.setUint16(12, substituteBytes + 2, Endian.little);
  view.setUint16(14, printBytes, Endian.little);

  var offset = _headerSize + _mountPointDataHeaderSize;
  for (final unit in substituteUnits) {
    view.setUint16(offset, unit, Endian.little);
    offset += 2;
  }
  offset += 2;
  for (final unit in printUnits) {
    view.setUint16(offset, unit, Endian.little);
    offset += 2;
  }

  return buffer;
}

String _decodePathBufferName(
  ByteData view,
  int pathBufferStart,
  int nameOffset,
  int nameLength,
) {
  final start = pathBufferStart + nameOffset;
  final codeUnits = <int>[
    for (var index = 0; index < nameLength; index += 2)
      view.getUint16(start + index, Endian.little),
  ];

  return String.fromCharCodes(codeUnits);
}

/// Decodes the `REPARSE_DATA_BUFFER` returned by `FSCTL_GET_REPARSE_POINT`
/// for mount points and symlinks.
ReparsePointData decodeReparseData(Uint8List data) {
  if (data.length < _headerSize + _mountPointDataHeaderSize) {
    throw ArgumentError.value(
      data,
      'data',
      'Reparse data buffer is too short (${data.length} bytes)',
    );
  }

  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final tag = view.getUint32(0, Endian.little);

  if (tag != ioReparseTagMountPoint && tag != ioReparseTagSymlink) {
    throw ArgumentError.value(
      data,
      'data',
      'Unsupported reparse tag: 0x${tag.toRadixString(16)}',
    );
  }

  final substituteNameOffset = view.getUint16(8, Endian.little);
  final substituteNameLength = view.getUint16(10, Endian.little);
  final printNameOffset = view.getUint16(12, Endian.little);
  final printNameLength = view.getUint16(14, Endian.little);
  final isSymlink = tag == ioReparseTagSymlink;
  final flags = isSymlink ? view.getUint32(16, Endian.little) : 0;
  final pathBufferStart =
      _headerSize +
      (isSymlink ? _symlinkDataHeaderSize : _mountPointDataHeaderSize);

  return ReparsePointData(
    tag: tag,
    substituteName: _decodePathBufferName(
      view,
      pathBufferStart,
      substituteNameOffset,
      substituteNameLength,
    ),
    printName: _decodePathBufferName(
      view,
      pathBufferStart,
      printNameOffset,
      printNameLength,
    ),
    flags: flags,
  );
}

/// Normalizes a reparse-point target for user consumption: converts NT
/// namespace prefixes (`\??\`, `\\?\`, including their `UNC\` forms) into
/// regular Win32 paths and strips trailing separators (while keeping drive
/// roots like `C:\` intact).
String normalizeReparseTarget(String target) {
  var normalized = target;

  for (final prefix in const [r'\??\', r'\\?\']) {
    if (normalized.startsWith(prefix)) {
      final rest = normalized.substring(prefix.length);
      normalized = rest.startsWith(r'UNC\') ? '\\\\${rest.substring(4)}' : rest;
      break;
    }
  }

  while (normalized.length > 1 &&
      (normalized.endsWith(r'\') || normalized.endsWith('/'))) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  if (normalized.endsWith(':')) {
    normalized = '$normalized\\';
  }

  return normalized;
}

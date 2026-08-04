// Single-syscall lstat fast path.
//
// `dart:io` metadata calls (`FileSystemEntity.type`, `FileStat.stat`) each
// round-trip through the IO event handler and, on Windows, open a file
// handle; `getPathStats` additionally issues two of them per existing path.
// On large trees (10k+ files) this dominated sync wall-clock time — see
// tool/benchmark_large_repo.dart.
//
// This module answers the common cases (plain file / plain directory /
// definitely missing) with ONE synchronous native call and NO IO-thread
// round trip. Every case it cannot answer with certainty — reparse points,
// unexpected error codes, very long paths, non-Windows platforms (for now) —
// reports [NativeStatOutcome.cannotAnswer] so callers fall back to the
// original `dart:io` implementation, which is kept verbatim in
// filesystem.dart. Behavior parity is therefore preserved by construction;
// `test/lib/native_stat_test.dart` pins field-for-field agreement with the
// dart:io reference on every fixture class.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Result classification of one fast-path lstat attempt.
enum NativeStatOutcome {
  /// The path exists and is a plain file or directory (never a link — those
  /// delegate to dart:io so reparse-tag semantics stay byte-identical).
  present,

  /// The path definitely does not exist.
  absent,

  /// The fast path cannot answer authoritatively; use the dart:io fallback.
  cannotAnswer,
}

/// Answer of [nativeLstatSync]: outcome plus (when [NativeStatOutcome.present])
/// the entity kind and a `FileStat.stat`-compatible mode.
class NativeStatAnswer {
  const NativeStatAnswer._(this.outcome, this.isDirectory, this.mode);

  static const NativeStatAnswer absent = NativeStatAnswer._(
    NativeStatOutcome.absent,
    false,
    0,
  );
  static const NativeStatAnswer cannotAnswer = NativeStatAnswer._(
    NativeStatOutcome.cannotAnswer,
    false,
    0,
  );

  final NativeStatOutcome outcome;
  final bool isDirectory;

  /// Synthesized CRT-compatible mode bits, matching what `FileStat.stat`
  /// reports on this platform (pinned by native_stat_test.dart).
  final int mode;

  bool get isFile => outcome == NativeStatOutcome.present && !isDirectory;
}

// Win32 constants (winnt.h / winerror.h).
const int _fileAttributeReadonly = 0x00000001;
const int _fileAttributeDirectory = 0x00000010;
const int _fileAttributeReparsePoint = 0x00000400;
const int _errorFileNotFound = 2;
const int _errorPathNotFound = 3;
const int _errorInvalidName = 123;
const int _errorDirectory = 267; // ERROR_DIRECTORY: path component not a dir.
const int _errorBadNetName = 67; // Missing network share member.

// CRT `_wstat64` mode synthesis (verified empirically on this SDK by the
// pinning tests): base 0o666, readonly drops write bits to 0o444, directories
// and executable extensions add 0o111, plus S_IFDIR/S_IFREG type bits.
const int _sIfDir = 0x4000; // 0o040000
const int _sIfReg = 0x8000; // 0o100000
const int _modeBaseWritable = 0x1B6; // 0o666
const int _modeBaseReadonly = 0x124; // 0o444
const int _modeExecuteBits = 0x49; // 0o111

// Paths near MAX_PATH need dart:io's `\\?\` long-path normalization; keep a
// comfortable margin below the 260-char limit and delegate the rest.
const int _maxFastPathLength = 240;

/// GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard.
const int _getFileExInfoStandard = 0;

/// WIN32_FILE_ATTRIBUTE_DATA (36 bytes).
final class _Win32FileAttributeData extends Struct {
  @Uint32()
  external int dwFileAttributes;
  @Uint32()
  external int ftCreationTimeLow;
  @Uint32()
  external int ftCreationTimeHigh;
  @Uint32()
  external int ftLastAccessTimeLow;
  @Uint32()
  external int ftLastAccessTimeHigh;
  @Uint32()
  external int ftLastWriteTimeLow;
  @Uint32()
  external int ftLastWriteTimeHigh;
  @Uint32()
  external int nFileSizeHigh;
  @Uint32()
  external int nFileSizeLow;
}

typedef _GetFileAttributesExWNative =
    Int32 Function(Pointer<Utf16>, Int32, Pointer<_Win32FileAttributeData>);
typedef _GetFileAttributesExWDart =
    int Function(Pointer<Utf16>, int, Pointer<_Win32FileAttributeData>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

final class _Kernel32 {
  factory _Kernel32() => _instance ??= _Kernel32._();

  // Both bindings are `isLeaf`: the calls run directly on the mutator thread
  // with no Dart<->native thread-state transition, and — critically — no VM
  // code runs between an adjacent GetFileAttributesExW/GetLastError pair, so
  // the thread's last-error value cannot be clobbered. package:win32 solves
  // the same problem differently, by capturing the code into a Win32Result
  // alongside each return value (cf. windows/win32_links.dart).
  _Kernel32._() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    getFileAttributesExW = kernel32
        .lookupFunction<_GetFileAttributesExWNative, _GetFileAttributesExWDart>(
          'GetFileAttributesExW',
          isLeaf: true,
        );
    getLastError = kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
          'GetLastError',
          isLeaf: true,
        );
  }

  static _Kernel32? _instance;

  late final _GetFileAttributesExWDart getFileAttributesExW;
  late final _GetLastErrorDart getLastError;
}

bool _hasExecutableExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.length - 4) {
    return false;
  }
  final extension = path.substring(dot).toLowerCase();
  return extension == '.exe' ||
      extension == '.bat' ||
      extension == '.cmd' ||
      extension == '.com';
}

int _synthesizeWindowsMode({
  required int attributes,
  required String path,
  required bool isDirectory,
}) {
  var mode = (attributes & _fileAttributeReadonly) != 0
      ? _modeBaseReadonly
      : _modeBaseWritable;

  if (isDirectory || _hasExecutableExtension(path)) {
    mode |= _modeExecuteBits;
  }

  return mode | (isDirectory ? _sIfDir : _sIfReg);
}

NativeStatAnswer _windowsLstat(String path) {
  final kernel32 = _Kernel32();
  final pathPointer = path.toNativeUtf16();
  final data = calloc<_Win32FileAttributeData>();

  try {
    final ok = kernel32.getFileAttributesExW(
      pathPointer,
      _getFileExInfoStandard,
      data,
    );

    if (ok == 0) {
      // Must be read immediately after the failing isLeaf call — no VM code
      // runs in between, so the value is reliable.
      final lastError = kernel32.getLastError();

      switch (lastError) {
        case _errorFileNotFound:
        case _errorPathNotFound:
        case _errorInvalidName:
        case _errorDirectory:
        case _errorBadNetName:
          // The same classes of "does not exist" that dart:io reports as
          // notFound (its stat helpers swallow lookup errors into notFound).
          return NativeStatAnswer.absent;
        default:
          // Access denied, sharing violations, offline volumes, ...: let the
          // dart:io implementation decide, byte-identically to today.
          return NativeStatAnswer.cannotAnswer;
      }
    }

    final attributes = data.ref.dwFileAttributes;

    if ((attributes & _fileAttributeReparsePoint) != 0) {
      // Symlinks, junctions, OneDrive placeholders, appexec links...: only
      // dart:io's tag inspection reproduces the current link-vs-file/dir
      // classification exactly. Rare on real trees; delegating costs one
      // dart:io round trip — exactly what every call paid before this
      // module existed.
      return NativeStatAnswer.cannotAnswer;
    }

    final isDirectory = (attributes & _fileAttributeDirectory) != 0;

    return NativeStatAnswer._(
      NativeStatOutcome.present,
      isDirectory,
      _synthesizeWindowsMode(
        attributes: attributes,
        path: path,
        isDirectory: isDirectory,
      ),
    );
  } finally {
    calloc.free(data);
    calloc.free(pathPointer);
  }
}

/// Attempts to answer an lstat (do-not-follow-links) query for [path] with a
/// single synchronous native call.
///
/// Windows-only for now; on other platforms (and for any path or outcome the
/// fast path cannot classify with certainty) returns
/// [NativeStatAnswer.cannotAnswer] and the caller must use the dart:io
/// implementation. Never returns a link classification: reparse points always
/// delegate. Blocking the isolate is intentional and safe — the call is
/// µs-scale with no locks, orders of magnitude cheaper than a dart:io IO
/// round trip.
NativeStatAnswer nativeLstatSync(String path) {
  if (!Platform.isWindows) {
    return NativeStatAnswer.cannotAnswer;
  }

  if (path.isEmpty || path.length > _maxFastPathLength) {
    return NativeStatAnswer.cannotAnswer;
  }

  return _windowsLstat(path);
}

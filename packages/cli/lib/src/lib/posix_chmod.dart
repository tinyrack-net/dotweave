/// `libc` `chmod` binding used to preserve POSIX file modes.
///
/// The lookups are initialized lazily so this library stays importable and
/// analyzable on Windows, where [posixChmod] must never be called (call sites
/// in `filesystem.dart` guard on `Platform.isWindows`).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _ChmodNative = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

_ChmodDart? _cachedChmod;
_ErrnoLocationDart? _cachedErrnoLocation;
bool _errnoLocationResolved = false;

_ChmodDart _loadChmod() {
  return _cachedChmod ??= DynamicLibrary.process()
      .lookupFunction<_ChmodNative, _ChmodDart>('chmod');
}

_ErrnoLocationDart? _loadErrnoLocation() {
  if (_errnoLocationResolved) {
    return _cachedErrnoLocation;
  }

  _errnoLocationResolved = true;
  final process = DynamicLibrary.process();

  // glibc / musl, macOS, and other BSDs expose errno through different
  // accessor symbols.
  for (final symbol in const ['__errno_location', '__error', '__errno']) {
    if (process.providesSymbol(symbol)) {
      _cachedErrnoLocation = process
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(symbol);
      break;
    }
  }

  return _cachedErrnoLocation;
}

/// Applies [mode] to [path] through `libc` `chmod`, mirroring Node's
/// `fs.chmod`. Throws a [FileSystemException] carrying the errno on failure.
void posixChmod(String path, int mode) {
  if (Platform.isWindows) {
    throw UnsupportedError('posixChmod is not supported on Windows');
  }

  final chmod = _loadChmod();

  using((arena) {
    final result = chmod(path.toNativeUtf8(allocator: arena), mode);

    if (result != 0) {
      final errno = _loadErrnoLocation()?.call().value ?? 0;

      throw FileSystemException(
        'chmod failed',
        path,
        OSError('chmod failed', errno),
      );
    }
  });
}

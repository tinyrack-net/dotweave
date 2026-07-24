/// Win32 FFI wrappers for symlink and junction management.
///
/// This library is only functional on Windows; the kernel32 bindings inside
/// `package:win32` are initialized lazily, so importing it on POSIX platforms
/// is safe as long as no function here is invoked.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as win32;

import 'reparse.dart';

const int _invalidFileAttributes = 0xFFFFFFFF;
const int _shareAll =
    win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE;

/// `package:win32` resolves each API through a lazy `GetProcAddress` lookup
/// on first use. If `GetLastError`'s own binding is resolved *after* a failed
/// call, that lookup clobbers the thread's last-error value (observed
/// empirically: the first cold read returns 0). Resolving the binding before
/// any operative call keeps the subsequent read accurate.
void _warmUpLastErrorBinding() {
  win32.GetLastError();
}

String _formatWin32Message(int code) {
  return using((arena) {
    const bufferLength = 512;
    final buffer = arena<Uint16>(bufferLength).cast<Utf16>();
    final length = win32.FormatMessage(
      win32.FORMAT_MESSAGE_FROM_SYSTEM | win32.FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr,
      code,
      0,
      buffer,
      bufferLength,
      nullptr,
    );

    if (length == 0) {
      return 'Win32 error $code';
    }

    return buffer.toDartString(length: length).trim();
  });
}

FileSystemException _lastErrorException(String message, String path) {
  final code = win32.GetLastError();

  return FileSystemException(
    message,
    path,
    OSError(_formatWin32Message(code), code),
  );
}

String _toWindowsSeparators(String path) {
  return path.replaceAll('/', r'\');
}

/// Creates an NTFS symbolic link at [path] pointing to [target] (stored
/// verbatim, so relative targets stay relative) via `CreateSymbolicLinkW`.
///
/// Always passes `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` so creation
/// succeeds without elevation when Developer Mode is enabled; on failure a
/// [FileSystemException] carrying the Win32 error code is thrown (for example
/// `ERROR_PRIVILEGE_NOT_HELD` when the OS denies symlink creation).
void createSymbolicLink(String target, String path, {required bool directory}) {
  _warmUpLastErrorBinding();
  using((arena) {
    final flags =
        (directory ? win32.SYMBOLIC_LINK_FLAG_DIRECTORY : 0) |
        win32.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    final result = win32.CreateSymbolicLink(
      path.toNativeUtf16(allocator: arena),
      _toWindowsSeparators(target).toNativeUtf16(allocator: arena),
      flags,
    );

    if (result == 0) {
      throw _lastErrorException('Symlink creation failed', path);
    }
  });
}

String _toJunctionTarget(String target) {
  var normalized = _toWindowsSeparators(target);

  while (normalized.length > 1 && normalized.endsWith(r'\')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  if (normalized.endsWith(':')) {
    normalized = '$normalized\\';
  }

  return normalized;
}

int _openReparseHandle(
  Arena arena,
  String path,
  int desiredAccess,
  String failureMessage,
) {
  final handle = win32.CreateFile(
    path.toNativeUtf16(allocator: arena),
    desiredAccess,
    _shareAll,
    nullptr,
    win32.OPEN_EXISTING,
    win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
    win32.NULL,
  );

  if (handle == win32.INVALID_HANDLE_VALUE) {
    throw _lastErrorException(failureMessage, path);
  }

  return handle;
}

/// Creates an NTFS junction (mount point) at [path] resolving to the
/// absolute directory [target].
///
/// Mirrors `mklink /J`: creates an empty directory, opens it with
/// `FILE_FLAG_OPEN_REPARSE_POINT`, and applies an
/// `IO_REPARSE_TAG_MOUNT_POINT` buffer whose substitute name is the
/// NT-prefixed target (`\??\C:\abs\path`) via `FSCTL_SET_REPARSE_POINT`.
void createJunction(String path, String target) {
  final normalizedTarget = _toJunctionTarget(target);

  if (!p.windows.isAbsolute(normalizedTarget)) {
    // Junction substitute names must be absolute because the kernel resolves
    // them directly, without a "current directory" context.
    throw ArgumentError.value(
      target,
      'target',
      'Junction targets must be absolute paths',
    );
  }

  _warmUpLastErrorBinding();
  Directory(path).createSync();

  try {
    using((arena) {
      final handle = _openReparseHandle(
        arena,
        path,
        win32.GENERIC_WRITE,
        'Junction creation failed',
      );

      try {
        final data = encodeMountPointReparseData(
          '\\??\\$normalizedTarget',
          normalizedTarget,
        );
        final buffer = arena<Uint8>(data.length);
        buffer.asTypedList(data.length).setAll(0, data);
        final bytesReturned = arena<Uint32>();
        final result = win32.DeviceIoControl(
          handle,
          win32.FSCTL_SET_REPARSE_POINT,
          buffer,
          data.length,
          nullptr,
          0,
          bytesReturned,
          nullptr,
        );

        if (result == 0) {
          throw _lastErrorException('Junction creation failed', path);
        }
      } finally {
        win32.CloseHandle(handle);
      }
    });
  } catch (error) {
    try {
      Directory(path).deleteSync();
    } catch (_) {
      // Preserve the original failure.
    }
    rethrow;
  }
}

/// Reads and decodes the reparse point stored at [path] via
/// `FSCTL_GET_REPARSE_POINT`.
///
/// Throws a [FileSystemException] carrying `ERROR_NOT_A_REPARSE_POINT`
/// (4390) when the node exists but is not a reparse point.
ReparsePointData readReparsePoint(String path) {
  _warmUpLastErrorBinding();

  return using((arena) {
    final handle = _openReparseHandle(
      arena,
      path,
      0,
      'Reparse point read failed',
    );

    try {
      final buffer = arena<Uint8>(maximumReparseDataBufferSize);
      final bytesReturned = arena<Uint32>();
      final result = win32.DeviceIoControl(
        handle,
        win32.FSCTL_GET_REPARSE_POINT,
        nullptr,
        0,
        buffer,
        maximumReparseDataBufferSize,
        bytesReturned,
        nullptr,
      );

      if (result == 0) {
        throw _lastErrorException('Reparse point read failed', path);
      }

      return decodeReparseData(
        Uint8List.fromList(buffer.asTypedList(bytesReturned.value)),
      );
    } finally {
      win32.CloseHandle(handle);
    }
  });
}

/// Deletes the symlink or junction node at [path] without ever touching the
/// link target's contents.
///
/// Refuses (with `ERROR_NOT_A_REPARSE_POINT`) to delete nodes that are not
/// reparse points, so a regular directory can never be removed through this
/// helper.
void deleteLinkNode(String path) {
  _warmUpLastErrorBinding();
  using((arena) {
    final nativePath = path.toNativeUtf16(allocator: arena);
    final attributes = win32.GetFileAttributes(nativePath);

    if (attributes == _invalidFileAttributes) {
      throw _lastErrorException('Link deletion failed', path);
    }

    if ((attributes & win32.FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
      throw FileSystemException(
        'Link deletion failed: not a reparse point',
        path,
        OSError(
          _formatWin32Message(win32.ERROR_NOT_A_REPARSE_POINT),
          win32.ERROR_NOT_A_REPARSE_POINT,
        ),
      );
    }

    final result = (attributes & win32.FILE_ATTRIBUTE_DIRECTORY) != 0
        ? win32.RemoveDirectory(nativePath)
        : win32.DeleteFile(nativePath);

    if (result == 0) {
      throw _lastErrorException('Link deletion failed', path);
    }
  });
}

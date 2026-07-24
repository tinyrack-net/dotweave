/// Filesystem error predicates that translate the Node error-code checks in
/// `filesystem.ts` (`ENOENT`, `ENOTDIR`, `EPERM`, ...) into the raw codes
/// surfaced by `dart:io`: POSIX errno values on Linux/macOS and Win32 error
/// codes on Windows.
///
/// Each predicate accepts any thrown value, extracts the [OSError] payload
/// from [FileSystemException] wrappers, and matches the platform-appropriate
/// code set.
library;

import 'dart:io';

// POSIX errno values.
const _eperm = 1;
const _enoent = 2;
const _eacces = 13;
const _eexist = 17;
const _exdev = 18;
const _enotdir = 20;
const _einval = 22;

// Win32 error codes.
const _errorFileNotFound = 2;
const _errorPathNotFound = 3;
const _errorAccessDenied = 5;
const _errorNotSameDevice = 17;
const _errorFileExists = 80;
const _errorInvalidParameter = 87;
const _errorAlreadyExists = 183;
const _errorDirectory = 267;
const _errorPrivilegeNotHeld = 1314;
const _errorNotAReparsePoint = 4390;

/// Extracts the numeric OS error code from a thrown value, unwrapping
/// [FileSystemException] and accepting bare [OSError] instances.
int? extractOsErrorCode(Object error) {
  if (error is FileSystemException) {
    return error.osError?.errorCode;
  }
  if (error is OSError) {
    return error.errorCode;
  }
  return null;
}

bool _matches(Object error, Set<int> posixCodes, Set<int> windowsCodes) {
  final code = extractOsErrorCode(error);
  if (code == null) {
    return false;
  }
  return Platform.isWindows
      ? windowsCodes.contains(code)
      : posixCodes.contains(code);
}

/// `ENOENT` — the path (or one of its ancestors) does not exist.
bool isNotFound(Object error) {
  return _matches(
    error,
    const {_enoent},
    const {_errorFileNotFound, _errorPathNotFound},
  );
}

/// `ENOTDIR` — a non-directory component was found where a directory was
/// expected. Windows reports `ERROR_DIRECTORY` (and sometimes
/// `ERROR_PATH_NOT_FOUND`) for the same condition.
bool isNotADirectory(Object error) {
  return _matches(
    error,
    const {_enotdir},
    const {_errorDirectory, _errorPathNotFound},
  );
}

/// The `EPERM || EINVAL` branch of `createSymlink`: the OS refused to create
/// a symlink for privilege reasons (no Developer Mode / not elevated, or an
/// unsupported unprivileged-create flag on older Windows builds).
bool isSymlinkPrivilegeError(Object error) {
  return _matches(
    error,
    const {_eperm, _einval},
    const {_errorPrivilegeNotHeld, _errorAccessDenied, _errorInvalidParameter},
  );
}

/// `EINVAL` — an invalid argument, including reading a reparse point from a
/// node that does not carry one (`ERROR_NOT_A_REPARSE_POINT`).
bool isInvalidArgument(Object error) {
  return _matches(
    error,
    const {_einval},
    const {_errorInvalidParameter, _errorNotAReparsePoint},
  );
}

/// `EEXIST` — the destination already exists.
bool isExists(Object error) {
  return _matches(
    error,
    const {_eexist},
    const {_errorAlreadyExists, _errorFileExists},
  );
}

/// `EXDEV` — a rename across devices/volumes that the OS cannot perform.
bool isCrossDevice(Object error) {
  return _matches(error, const {_exdev}, const {_errorNotSameDevice});
}

/// `EACCES` — permission denied.
bool isPermissionDenied(Object error) {
  return _matches(error, const {_eacces}, const {_errorAccessDenied});
}

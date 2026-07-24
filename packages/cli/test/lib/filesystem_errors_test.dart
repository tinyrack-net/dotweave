import 'dart:io';

import 'package:dotweave/src/lib/fs_errors.dart';
import 'package:test/test.dart';

/// Builds the [FileSystemException] shape thrown by `dart:io`, carrying the
/// platform-native code the way Node errors carry `error.code`.
FileSystemException fsException(String message, int code) {
  return FileSystemException(message, '/tmp/value', OSError(message, code));
}

int platformCode({required int posix, required int windows}) {
  return Platform.isWindows ? windows : posix;
}

void main() {
  group('filesystem helpers - error cases', () {
    // `pathExists` only swallows not-found errors, so an access-denied
    // failure must not satisfy the not-found predicate.
    test('handles EACCES error in pathExists', () {
      final error = fsException('EACCES', platformCode(posix: 13, windows: 5));

      expect(isNotFound(error), false);
      expect(isPermissionDenied(error), true);
    });

    // `getPathStats` treats only ENOENT/ENOTDIR as absent; EPERM must be
    // re-thrown.
    test('handles non-ENOENT error in getPathStats', () {
      final error = fsException('EPERM', platformCode(posix: 1, windows: 1314));

      expect(isNotFound(error), false);
      expect(isNotADirectory(error), false);
    });

    test('treats ENOTDIR as absent in getPathStats', () {
      final error = fsException(
        'ENOTDIR',
        platformCode(posix: 20, windows: 267),
      );

      expect(isNotFound(error) || isNotADirectory(error), true);
    });

    test('treats ENOENT as absent in getPathStats', () {
      final error = fsException('ENOENT', 2);

      expect(isNotFound(error), true);
    });

    // `pathExists` re-throws everything that is not ENOENT. On Windows the
    // dedicated ENOTDIR code is ERROR_DIRECTORY (267); ERROR_PATH_NOT_FOUND
    // (3) folds into not-found, exactly like Node maps winerror 3 to ENOENT.
    test('re-throws ENOTDIR error in pathExists', () {
      final error = fsException(
        'ENOTDIR',
        platformCode(posix: 20, windows: 267),
      );

      expect(isNotFound(error), false);
    });

    test('re-throws EISDIR error in pathExists', () {
      final error = fsException('EISDIR', 21);

      expect(isNotFound(error), false);
      expect(isNotADirectory(error), false);
    });

    test('re-throws EMFILE error in getPathStats', () {
      final error = fsException('EMFILE', platformCode(posix: 24, windows: 4));

      expect(isNotFound(error), false);
      expect(isNotADirectory(error), false);
    });

    test('treats ENOTDIR as absent in getFollowedPathStats', () {
      final error = fsException(
        'ENOTDIR',
        platformCode(posix: 20, windows: 267),
      );

      expect(isNotFound(error) || isNotADirectory(error), true);
    });
  });

  group('filesystem error predicates', () {
    test('extracts OS error codes from FileSystemException and OSError', () {
      expect(extractOsErrorCode(fsException('ENOENT', 2)), 2);
      expect(extractOsErrorCode(const OSError('EEXIST', 17)), 17);
      expect(
        extractOsErrorCode(const FileSystemException('no os error')),
        isNull,
      );
      expect(extractOsErrorCode(Exception('not filesystem')), isNull);
      expect(extractOsErrorCode(StateError('nope')), isNull);
    });

    test('isNotFound matches missing-path codes', () {
      expect(
        isNotFound(fsException('ENOENT', platformCode(posix: 2, windows: 2))),
        true,
      );
      if (Platform.isWindows) {
        expect(isNotFound(fsException('ERROR_PATH_NOT_FOUND', 3)), true);
      }
      expect(isNotFound(Exception('no code')), false);
    });

    test('isNotADirectory matches non-directory ancestor codes', () {
      expect(
        isNotADirectory(
          fsException('ENOTDIR', platformCode(posix: 20, windows: 267)),
        ),
        true,
      );
    });

    test('isSymlinkPrivilegeError matches the EPERM || EINVAL branch', () {
      final codes = Platform.isWindows ? const [1314, 5, 87] : const [1, 22];

      for (final code in codes) {
        expect(isSymlinkPrivilegeError(fsException('denied', code)), true);
      }

      expect(isSymlinkPrivilegeError(fsException('ENOENT', 2)), false);
    });

    test('isInvalidArgument matches EINVAL and non-reparse-point reads', () {
      final codes = Platform.isWindows ? const [87, 4390] : const [22];

      for (final code in codes) {
        expect(isInvalidArgument(fsException('EINVAL', code)), true);
      }
    });

    test('isExists matches EEXIST codes', () {
      final codes = Platform.isWindows ? const [183, 80] : const [17];

      for (final code in codes) {
        expect(isExists(fsException('EEXIST', code)), true);
      }
    });

    test('isCrossDevice matches EXDEV without clashing with EEXIST', () {
      expect(
        isCrossDevice(
          fsException('EXDEV', platformCode(posix: 18, windows: 17)),
        ),
        true,
      );

      // POSIX errno 17 is EEXIST and Win32 17 is ERROR_NOT_SAME_DEVICE; the
      // platform gate keeps the two predicates disjoint.
      if (!Platform.isWindows) {
        expect(isCrossDevice(fsException('EEXIST', 17)), false);
        expect(isExists(fsException('EXDEV', 18)), false);
      }
    });

    test('isPermissionDenied matches EACCES codes', () {
      expect(
        isPermissionDenied(
          fsException('EACCES', platformCode(posix: 13, windows: 5)),
        ),
        true,
      );
      expect(isPermissionDenied(fsException('ENOENT', 2)), false);
    });
  });
}

import 'dart:io';

import 'package:dotweave/src/lib/path_util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mirrors node:path `resolve` for computing platform-dependent expectations.
String resolve(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

void main() {
  group('path helpers', () {
    test('builds repository directory keys', () {
      expect(buildDirectoryKey('bundle/cache'), 'bundle/cache/');
    });

    test('detects nested and overlapping paths', () {
      expect(
        isPathEqualOrNested('/tmp/home/project/file.txt', '/tmp/home'),
        true,
      );
      expect(isPathEqualOrNested('/tmp/elsewhere', '/tmp/home'), false);
      expect(doPathsOverlap('/tmp/home/project', '/tmp/home'), true);
      expect(doPathsOverlap('/tmp/home/one', '/tmp/home/two'), false);
    });

    test('handles trailing slashes in doPathsOverlap', () {
      expect(doPathsOverlap('/tmp/home/', '/tmp/home'), true);
    });

    test('detects equal paths as overlapping in doPathsOverlap', () {
      expect(doPathsOverlap('/tmp/home', '/tmp/home'), true);
    });

    test('isExplicitLocalPath returns false for bare filenames', () {
      expect(isExplicitLocalPath('filename'), false);
    });

    test('buildDirectoryKey handles already-trailing-slashed paths', () {
      expect(buildDirectoryKey('dir/'), 'dir//');
    });

    test('isPathEqualOrNested returns true for equal paths', () {
      expect(isPathEqualOrNested('/tmp/home', '/tmp/home'), true);
    });

    test('recognizes explicit local path inputs', () {
      expect(isExplicitLocalPath('.'), true);
      expect(isExplicitLocalPath('~/bundle'), true);
      expect(isExplicitLocalPath('../bundle'), true);
      expect(isExplicitLocalPath('bundle/file.txt'), false);
    });

    group('normalizeLinkTarget', () {
      test('returns absolute target as-is on non-windows', () {
        expect(normalizeLinkTarget('/usr/bin/python3'), '/usr/bin/python3');
      });

      test('resolves relative target against baseDir', () {
        final expected = Platform.isWindows
            ? resolve([
                '/opt/app/venv',
                '../bin/python3',
              ]).replaceAll(r'\', '/').toLowerCase()
            : '/opt/app/bin/python3';
        expect(
          normalizeLinkTarget('../bin/python3', '/opt/app/venv'),
          expected,
        );
      });

      test('ignores baseDir for absolute target', () {
        expect(
          normalizeLinkTarget('/usr/bin/python3', '/opt/app'),
          '/usr/bin/python3',
        );
      });

      test('returns target unchanged when no baseDir is given', () {
        expect(normalizeLinkTarget('relative/path'), 'relative/path');
      });

      test('resolves dot-slash relative target against baseDir', () {
        final expected = Platform.isWindows
            ? resolve([
                '/home/user',
                './script.sh',
              ]).replaceAll(r'\', '/').toLowerCase()
            : '/home/user/script.sh';
        expect(normalizeLinkTarget('./script.sh', '/home/user'), expected);
      });

      test('returns resolved targets unchanged for non-windows platforms', () {
        expect(
          normalizeLinkTargetWithDependencies(
            '../bin/python3',
            '/opt/app/venv',
            platform: 'linux',
            isAbsolutePath: (path) => path.startsWith('/'),
            resolvePath: (paths) =>
                paths.join('/').replaceFirst('venv/../', ''),
          ),
          '/opt/app/bin/python3',
        );
      });

      test('normalizes windows realpath results', () {
        expect(
          normalizeLinkTargetWithDependencies(
            r'C:\Users\Me\File.txt',
            null,
            platform: 'win32',
            isAbsolutePath: (path) =>
                RegExp(r'^[a-z]:', caseSensitive: false).hasMatch(path),
            realpathSyncNative: (path) => r'C:\Users\ME\File.txt',
          ),
          'c:/users/me/file.txt',
        );
      });

      test(
        'falls back to parent realpath plus basename for missing windows targets with baseDir',
        () {
          String realpathSyncNative(String path) {
            if (path == r'C:\Users\Me\missing.txt') {
              throw Exception('missing target');
            }

            expect(path, r'C:\Users\Me');
            return r'C:\USERS\Me';
          }

          expect(
            normalizeLinkTargetWithDependencies(
              'missing.txt',
              r'C:\Users\Me',
              platform: 'win32',
              isAbsolutePath: (path) =>
                  RegExp(r'^[a-z]:', caseSensitive: false).hasMatch(path),
              resolvePath: (paths) => paths.join(r'\'),
              dirnamePath: (path) => path.substring(0, path.lastIndexOf(r'\')),
              basenamePath: (path) =>
                  path.substring(path.lastIndexOf(r'\') + 1),
              joinPath: (paths) => paths.join(r'\'),
              realpathSyncNative: realpathSyncNative,
            ),
            'c:/users/me/missing.txt',
          );
        },
      );

      test('resolves windows root-relative targets before normalization', () {
        expect(
          normalizeLinkTargetWithDependencies(
            r'\Foo\Bar',
            null,
            platform: 'win32',
            isAbsolutePath: (path) => path.startsWith(r'\'),
            resolvePath: (paths) => 'C:\\Current${paths.single}',
            realpathSyncNative: (path) => throw Exception('missing target'),
          ),
          'c:/current/foo/bar',
        );
      });

      test('does not resolve windows UNC targets as root-relative', () {
        expect(
          normalizeLinkTargetWithDependencies(
            r'\\Server\Share\File',
            null,
            platform: 'win32',
            isAbsolutePath: (path) => path.startsWith(r'\\'),
            resolvePath: (paths) => throw Exception(
              'UNC paths should not be resolved as root-relative',
            ),
            realpathSyncNative: (path) => throw Exception('missing target'),
          ),
          '//server/share/file',
        );
      });

      test('normalizes missing windows targets without baseDir', () {
        expect(
          normalizeLinkTargetWithDependencies(
            r'C:\Users\ME\Missing.txt',
            null,
            platform: 'win32',
            isAbsolutePath: (path) =>
                RegExp(r'^[a-z]:', caseSensitive: false).hasMatch(path),
            realpathSyncNative: (path) => throw Exception('missing target'),
          ),
          'c:/users/me/missing.txt',
        );
      });
    });
  });
}

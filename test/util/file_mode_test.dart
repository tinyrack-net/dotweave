import 'package:dotweave/src/util/file_mode.dart';
import 'package:test/test.dart';

/// Dart has no octal literals; mirrors the TS `0o...` test values.
int octal(String digits) => int.parse(digits, radix: 8);

void main() {
  group('file mode helpers', () {
    test('builds and detects executable modes', () {
      expect(buildExecutableMode(true), octal('755'));
      expect(buildExecutableMode(false), octal('644'));
      expect(isExecutableMode(octal('100755')), true);
      expect(isExecutableMode(octal('100644')), false);
    });

    test('builds searchable directory modes from configured permissions', () {
      expect(buildSearchableDirectoryMode(octal('000')), octal('000'));
      expect(buildSearchableDirectoryMode(octal('400')), octal('500'));
      expect(buildSearchableDirectoryMode(octal('600')), octal('700'));
      expect(buildSearchableDirectoryMode(octal('644')), octal('755'));
      expect(buildSearchableDirectoryMode(octal('700')), octal('700'));
      expect(buildSearchableDirectoryMode(octal('755')), octal('755'));
    });
  });

  group('permission octal helpers', () {
    test('validates permission octal strings', () {
      expect(isPermissionOctal('0600'), true);
      expect(isPermissionOctal('0755'), true);
      expect(isPermissionOctal('0644'), true);
      expect(isPermissionOctal('0000'), true);
      expect(isPermissionOctal('0777'), true);

      expect(isPermissionOctal('600'), false);
      expect(isPermissionOctal('0800'), false);
      expect(isPermissionOctal('07755'), false);
      expect(isPermissionOctal(''), false);
      expect(isPermissionOctal('abcd'), false);
      expect(isPermissionOctal('0x1FF'), false);
    });

    test('parses valid permission octal strings', () {
      expect(parsePermissionOctal('0600'), octal('600'));
      expect(parsePermissionOctal('0755'), octal('755'));
      expect(parsePermissionOctal('0644'), octal('644'));
      expect(parsePermissionOctal('0000'), octal('000'));
      expect(parsePermissionOctal('0777'), octal('777'));
      expect(parsePermissionOctal('0400'), octal('400'));
    });

    test('throws on invalid permission octal strings', () {
      final throwsInvalidPermissionOctal = throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'toString',
          contains('Invalid permission octal'),
        ),
      );

      expect(() => parsePermissionOctal('600'), throwsInvalidPermissionOctal);
      expect(() => parsePermissionOctal('0800'), throwsInvalidPermissionOctal);
      expect(() => parsePermissionOctal(''), throwsInvalidPermissionOctal);
    });

    test('formats permission modes to octal strings', () {
      expect(formatPermissionOctal(octal('600')), '0600');
      expect(formatPermissionOctal(octal('755')), '0755');
      expect(formatPermissionOctal(octal('644')), '0644');
      expect(formatPermissionOctal(octal('000')), '0000');
      expect(formatPermissionOctal(octal('777')), '0777');
      expect(formatPermissionOctal(octal('400')), '0400');
    });

    test('masks higher bits when formatting', () {
      expect(formatPermissionOctal(octal('100644')), '0644');
      expect(formatPermissionOctal(octal('100755')), '0755');
    });
  });
}

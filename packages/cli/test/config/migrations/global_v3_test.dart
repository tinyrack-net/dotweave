import 'package:dotweave/src/config/migrations/global_v3.dart';
import 'package:test/test.dart';

void main() {
  group('migrateGlobalConfigV2ToV3', () {
    test('removes the age field and updates version to 3', () {
      final result = migrateGlobalConfigV2ToV3({
        'version': 2,
        'activeProfile': 'work',
        'age': {
          'identityFile': '~/.config/dotweave/keys.txt',
          'recipients': ['age1abc'],
        },
      });

      expect(result, equals({'version': 3, 'activeProfile': 'work'}));
    });

    test('preserves activeProfile when present', () {
      final result = migrateGlobalConfigV2ToV3({
        'version': 2,
        'activeProfile': 'personal',
      });

      expect(result, equals({'version': 3, 'activeProfile': 'personal'}));
    });

    test('works when activeProfile is absent', () {
      final result = migrateGlobalConfigV2ToV3({'version': 2});
      expect(result, equals({'version': 3}));
    });

    test('removes age even when activeProfile is absent', () {
      final result = migrateGlobalConfigV2ToV3({
        'version': 2,
        'age': {
          'recipients': ['age1xyz'],
        },
      });

      expect(result, equals({'version': 3}));
    });
  });
}

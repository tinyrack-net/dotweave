import 'package:dotweave/src/config/migrations/sync_v8.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:test/test.dart';

void main() {
  group('sync v8 migration', () {
    test(
      'normalizes and deduplicates legacy entry profiles for the registry',
      () {
        expect(
          migrateSyncConfigV7ToV8({
            'version': 7,
            'entries': [
              {
                'profiles': [' default ', 'work', ' work ', 'Personal'],
              },
              {
                'profiles': ['default', 'Personal'],
              },
              {'profiles': null},
            ],
          }),
          equals({
            'version': 8,
            'entries': [
              {
                'profiles': [' default ', 'work', ' work ', 'Personal'],
              },
              {
                'profiles': ['default', 'Personal'],
              },
              {'profiles': null},
            ],
            'profiles': ['Personal', 'work'],
          }),
        );
      },
    );

    test('fails before producing a migrated config when a legacy profile name '
        'is invalid', () {
      expect(
        () => migrateSyncConfigV7ToV8({
          'version': 7,
          'entries': [
            {
              'profiles': ['bad/profile'],
            },
          ],
        }),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            'Profile name contains unsupported characters.',
          ),
        ),
      );
    });

    test('fails before producing a migrated config when a legacy profile value '
        'is not a string', () {
      expect(
        () => migrateSyncConfigV7ToV8({
          'version': 7,
          'entries': [
            {
              'profiles': ['work', 123],
            },
          ],
        }),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            'Profile name must be a string.',
          ),
        ),
      );
    });
  });
}

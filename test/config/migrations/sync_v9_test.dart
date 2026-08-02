import 'package:dotweave/src/config/migrations/sync_v9.dart';
import 'package:test/test.dart';

void main() {
  test('sync v9 migration preserves fields and only updates the version', () {
    expect(
      migrateSyncConfigV8ToV9({
        'version': 8,
        'profiles': ['work'],
        'entries': <Object?>[],
      }),
      {
        'version': 9,
        'profiles': ['work'],
        'entries': <Object?>[],
      },
    );
  });
}

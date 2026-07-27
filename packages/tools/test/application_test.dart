import 'package:dotweave_tools/src/application.dart';
import 'package:test/test.dart';

void main() {
  test('prints usage and fails for empty arguments', () async {
    expect(await runTools(const []), 64);
  });

  test('prints usage and succeeds for --help', () async {
    expect(await runTools(const ['--help']), 0);
  });

  test('fails for unknown commands', () async {
    expect(await runTools(const ['frobnicate']), 64);
  });

  test('fails with a clean error for an invalid release type', () async {
    expect(await runTools(const ['release', 'huge']), 1);
  });

  test('fails with a clean error for unknown release options', () async {
    expect(await runTools(const ['release', 'patch', '--bogus']), 1);
  });

  test('fails for verify without a subcommand', () async {
    expect(await runTools(const ['verify']), 1);
  });

  test('fails for msix without a subcommand', () async {
    expect(await runTools(const ['msix']), 1);
  });

  test('fails for smoke without --executable-path', () async {
    expect(await runTools(const ['smoke']), 1);
  });

  test('fails cleanly for unsupported validation targets', () async {
    for (final target in ['unknown', 'all', 'homepage']) {
      expect(await runTools(['validate', target]), 1);
    }
  });
}

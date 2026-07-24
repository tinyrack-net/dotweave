import 'package:dotweave/src/config/identity_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mirrors node:path `resolve` (see the TS test's `resolve` import).
String resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

void main() {
  group('identity file config', () {
    test('uses keys.txt under the resolved dotweave home directory', () {
      expect(
        resolveDefaultIdentityFile('/tmp/dotweave-home'),
        resolvePath(['/tmp/dotweave-home', 'keys.txt']),
      );
    });
  });
}

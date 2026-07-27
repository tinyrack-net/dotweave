import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

void main() {
  test('IoGitClient preserves porcelain status prefixes', () async {
    final temporary = await Directory.systemTemp.createTemp('shipworld-git-');
    addTearDown(() => temporary.delete(recursive: true));
    final tracked = File(p.join(temporary.path, 'tracked.txt'));

    await Process.run('git', ['init'], workingDirectory: temporary.path);
    await tracked.writeAsString('before\n');
    await Process.run('git', [
      'add',
      'tracked.txt',
    ], workingDirectory: temporary.path);
    await Process.run('git', [
      '-c',
      'user.name=Shipworld Test',
      '-c',
      'user.email=shipworld@example.invalid',
      'commit',
      '-m',
      'initial',
    ], workingDirectory: temporary.path);
    await tracked.writeAsString('after\n');

    final status = await const IoGitClient().run([
      'status',
      '--porcelain',
    ], workingDirectory: temporary.path);

    expect(status, ' M tracked.txt');
  });
}

// Dart port of `packages/cli/tests/concurrency.e2e.test.ts`.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('concurrency e2e', () {
    test('handles a large number of files during push and pull', () async {
      final appDirectory = p.join(ctx.homeDir, 'large-app');
      const fileCount = 100;

      await Directory(appDirectory).create(recursive: true);

      final fileNames = List.generate(fileCount, (i) => 'file-$i.txt');

      for (final fileName in fileNames) {
        await File(
          p.join(appDirectory, fileName),
        ).writeAsString('content for $fileName\n');
      }

      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);

      // Init and track
      await ctx.runCli(['init']);
      await ctx.runCli(['track', appDirectory]);

      // Push
      final pushResult = await ctx.runCli(['push']);
      expect(pushResult.exitCode, 0);
      expect(pushResult.stdout, contains('Push complete'));
      expect(pushResult.stdout, contains('plain: $fileCount'));

      // Modify some files locally to trigger updates during pull later
      for (var i = 0; i < 20; i += 1) {
        final fileName = fileNames[i];
        await File(
          p.join(appDirectory, fileName),
        ).writeAsString('modified content $i\n');
      }

      // Push again (updates)
      final pushUpdateResult = await ctx.runCli(['push']);
      expect(pushUpdateResult.exitCode, 0);

      // Pull to a fresh location (effectively)
      // We'll delete the local files and pull
      for (final fileName in fileNames) {
        await File(p.join(appDirectory, fileName)).writeAsString('corrupted\n');
      }

      final pullResult = await ctx.runCli(['pull', '-y']);
      expect(pullResult.exitCode, 0);

      // Verify all files are restored correctly
      for (var i = 0; i < fileCount; i += 1) {
        final fileName = fileNames[i];
        final content = await File(
          p.join(appDirectory, fileName),
        ).readAsString();
        if (i < 20) {
          expect(content, 'modified content $i\n');
        } else {
          expect(content, 'content for $fileName\n');
        }
      }
    });
  });
}

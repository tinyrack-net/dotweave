import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:test/test.dart';

// The identity-source precedence rule (explicit key > prompt > existing
// identity > generate) used to live as five interleaved booleans inside the
// `init` command, reachable only by driving the command. As a service
// function it is a table.

Future<AgeIdentityPlan> plan({
  String? keyFile,
  String? keyFileContents,
  String? repository,
  bool force = false,
  bool identityExists = false,
}) {
  return planAgeIdentity(
    keyFile: keyFile,
    repository: repository,
    force: force,
    readKeyFile: (_) async => keyFileContents ?? '',
    resolveIdentityFile: () => '/identity',
    identityFileExists: (_) async => identityExists,
  );
}

void main() {
  group('planAgeIdentity', () {
    test(
      'prompts only when adopting a repository with no key available',
      () async {
        // Prompting is for the one case where dotweave cannot proceed without
        // input: an existing repository whose artifacts need a key to read.
        expect(
          (await plan(
            repository: 'git@example.com:me/dotfiles.git',
          )).shouldPrompt,
          isTrue,
        );

        expect(
          (await plan()).shouldPrompt,
          isFalse,
          reason: 'fresh local init',
        );
        expect(
          (await plan(
            repository: 'git@example.com:me/dotfiles.git',
            identityExists: true,
          )).shouldPrompt,
          isFalse,
          reason: 'an identity is already on disk',
        );
        expect(
          (await plan(
            repository: 'git@example.com:me/dotfiles.git',
            keyFile: '/keys.txt',
            keyFileContents: 'AGE-SECRET-KEY-1TEST',
          )).shouldPrompt,
          isFalse,
          reason: 'a key was supplied explicitly',
        );
      },
    );

    test(
      'does not prompt on top of a key file that turned out blank',
      () async {
        final result = await plan(
          repository: 'git@example.com:me/dotfiles.git',
          keyFile: '/keys.txt',
          keyFileContents: '   \n',
        );

        expect(result.providedKey, isNull);
        expect(result.shouldPrompt, isFalse);
      },
    );

    test('--force ignores an identity already on disk', () async {
      expect(
        (await plan(identityExists: true, force: true)).identityFileExists,
        isFalse,
      );
      expect((await plan(identityExists: true)).identityFileExists, isTrue);
    });

    test('trims the key read from the key file', () async {
      expect(
        (await plan(
          keyFile: '/keys.txt',
          keyFileContents: '  AGE-SECRET-KEY-1TEST\n',
        )).providedKey,
        'AGE-SECRET-KEY-1TEST',
      );
    });
  });

  group('resolveAgeIdentity', () {
    test('an explicit key wins over everything and never generates', () async {
      final result = resolveAgeIdentity(
        await plan(keyFile: '/keys.txt', keyFileContents: 'KEY'),
        null,
      );

      expect(result.ageIdentity, 'KEY');
      expect(result.generateAgeIdentity, isFalse);
    });

    test('generates for a fresh local init with no identity on disk', () async {
      final result = resolveAgeIdentity(await plan(), null);

      expect(result.ageIdentity, isNull);
      expect(result.generateAgeIdentity, isTrue);
    });

    test('reuses the identity already on disk instead of generating', () async {
      final result = resolveAgeIdentity(await plan(identityExists: true), null);

      expect(result.ageIdentity, isNull);
      expect(result.generateAgeIdentity, isFalse);
    });

    test('adopts the key entered at the prompt', () async {
      final result = resolveAgeIdentity(
        await plan(repository: 'git@example.com:me/dotfiles.git'),
        '  AGE-SECRET-KEY-1TYPED  ',
      );

      expect(result.ageIdentity, 'AGE-SECRET-KEY-1TYPED');
      expect(result.generateAgeIdentity, isFalse);
    });

    test(
      'refuses to adopt a repository when the prompt is answered blank',
      () async {
        // Proceeding would leave every secret artifact undecryptable.
        await expectLater(
          () async => resolveAgeIdentity(
            await plan(repository: 'git@example.com:me/dotfiles.git'),
            '',
          ),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.code,
              'code',
              'INIT_AGE_IDENTITY_REQUIRED',
            ),
          ),
        );
      },
    );

    test('a blank prompt answer on a local init generates instead', () async {
      // Same blank answer, opposite outcome: with no repository to adopt,
      // "just make me one" is the sensible reading.
      final result = resolveAgeIdentity(await plan(), '');

      expect(result.ageIdentity, isNull);
      expect(result.generateAgeIdentity, isTrue);
    });
  });
}

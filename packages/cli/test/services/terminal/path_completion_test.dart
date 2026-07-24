import 'dart:io';

import 'package:dotweave/src/services/terminal/path_completion.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final List<String> _temporaryDirectories = [];

Future<String> _createWorkspace() async {
  final directory = await Directory.systemTemp.createTemp(
    'dotweave-path-complete-',
  );

  _temporaryDirectories.add(directory.path);

  return directory.path;
}

Future<void> _writeFile(String path) async {
  await File(path).writeAsString('');
}

void main() {
  tearDown(() async {
    while (_temporaryDirectories.isNotEmpty) {
      final directory = _temporaryDirectories.removeLast();
      final entity = Directory(directory);

      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    }
  });

  group('path completions', () {
    test('completes relative entries and hides dotfiles by default', () async {
      final workspace = await _createWorkspace();

      await _writeFile(p.join(workspace, 'file-alpha.txt'));
      await _writeFile(p.join(workspace, '.secret'));
      await Directory(p.join(workspace, 'folder-beta')).create();

      String cwd() => workspace;

      expect(await proposePathCompletions('f', cwd: cwd), [
        'file-alpha.txt',
        'folder-beta/',
      ]);
      expect(await proposePathCompletions('.s', cwd: cwd), ['.secret']);
    });

    test('completes home-relative and absolute paths', () async {
      final workspace = await _createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final nestedDirectory = p.join(homeDirectory, '.config');

      await Directory(nestedDirectory).create(recursive: true);
      await _writeFile(p.join(nestedDirectory, 'dotweave.toml'));
      await Directory(p.join(nestedDirectory, 'nvim')).create();

      String homedir() => homeDirectory;

      expect(await proposePathCompletions('~/.config/d', homedir: homedir), [
        '~/.config/dotweave.toml',
      ]);
      expect(await proposePathCompletions('$nestedDirectory/n'), [
        '$nestedDirectory/nvim/',
      ]);
    });

    test('returns an empty list for recoverable filesystem errors', () async {
      expect(
        await proposePathCompletions('nonexistent-path-prefix/'),
        <String>[],
      );
    });

    test('appends trailing slash to directory completions', () async {
      final workspace = await _createWorkspace();

      await Directory(p.join(workspace, 'docs')).create();

      expect(await proposePathCompletions('d', cwd: () => workspace), [
        'docs/',
      ]);
    });

    test('completes nested directory paths', () async {
      final workspace = await _createWorkspace();

      await Directory(
        p.join(workspace, 'workspace', 'project-a'),
      ).create(recursive: true);
      await Directory(
        p.join(workspace, 'workspace', 'project-b'),
      ).create(recursive: true);

      expect(await proposePathCompletions('workspace/', cwd: () => workspace), [
        'workspace/project-a/',
        'workspace/project-b/',
      ]);
    });

    test(
      'completes dotfile paths when explicitly prefixed with a dot',
      () async {
        final workspace = await _createWorkspace();

        await _writeFile(p.join(workspace, '.bashrc'));
        await _writeFile(p.join(workspace, '.vimrc'));

        expect(await proposePathCompletions('.', cwd: () => workspace), [
          '.bashrc',
          '.vimrc',
        ]);
      },
    );

    test(
      'completes paths starting with dot when explicitly prefixed',
      () async {
        final workspace = await _createWorkspace();
        final homeDirectory = p.join(workspace, 'home');

        await Directory(
          p.join(homeDirectory, '.config', 'nvim'),
        ).create(recursive: true);
        await Directory(
          p.join(homeDirectory, '.config', 'git'),
        ).create(recursive: true);

        expect(
          await proposePathCompletions(
            '~/.config/',
            homedir: () => homeDirectory,
          ),
          ['~/.config/git/', '~/.config/nvim/'],
        );
      },
    );

    test('handles completions for paths with no matches', () async {
      final workspace = await _createWorkspace();

      await _writeFile(p.join(workspace, 'file-alpha.txt'));

      expect(
        await proposePathCompletions('zzz-no-match', cwd: () => workspace),
        <String>[],
      );
    });
  });
}

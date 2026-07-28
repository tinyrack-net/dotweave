import 'package:dotweave/src/util/collation.dart';
import 'package:test/test.dart';

void main() {
  group('compareLocaleLike', () {
    test('orders case-insensitively like Node localeCompare', () {
      final names = ['Banana', 'apple', 'cherry', 'Apricot'];
      names.sort(compareLocaleLike);
      expect(names, ['apple', 'Apricot', 'Banana', 'cherry']);
    });

    test('places lowercase before uppercase on case-only ties', () {
      final names = ['Ab', 'ab', 'aB'];
      names.sort(compareLocaleLike);
      expect(names, ['ab', 'aB', 'Ab']);
    });

    test('sorts digits and dots before letters', () {
      final names = ['zshrc', '.zshrc', '1file'];
      names.sort(compareLocaleLike);
      expect(names, ['.zshrc', '1file', 'zshrc']);
    });

    test('returns zero for identical strings', () {
      expect(compareLocaleLike('same', 'same'), 0);
    });
  });
}

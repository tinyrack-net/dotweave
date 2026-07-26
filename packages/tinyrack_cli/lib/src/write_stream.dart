import 'dart:io' as io;

/// The slice of an output stream a CLI needs: write text, know whether it is
/// attached to a terminal, and move the cursor for in-place updates.
///
/// Mirrors Node's
/// `Pick<NodeJS.WriteStream, "write" | "isTTY" | "clearLine" | "cursorTo">`.
/// Named `WriteStream` rather than `Stream` so it does not shadow
/// `dart:async`'s `Stream` in every consumer.
///
/// Implement this to capture output in tests; see [StdioWriteStream] for the
/// process-stream implementation.
abstract class WriteStream {
  /// Whether the stream is attached to an interactive terminal. Spinners and
  /// ANSI colour are suppressed when this is false.
  bool get isTTY;

  /// Writes [chunk] verbatim. No newline is appended.
  void write(String chunk);

  /// Clears part of the current line: to its start when [dir] is negative, to
  /// its end when positive, and the whole line at zero.
  void clearLine(int dir);

  /// Moves the cursor to [column], counted from zero.
  void cursorTo(int column);
}

/// Adapts a `dart:io` [io.Stdout] to [WriteStream], emitting the same ANSI
/// sequences Node's `clearLine`/`cursorTo` write.
class StdioWriteStream implements WriteStream {
  StdioWriteStream(this._sink);

  final io.Stdout _sink;

  @override
  bool get isTTY => _sink.hasTerminal;

  @override
  void write(String chunk) {
    _sink.write(chunk);
  }

  @override
  void clearLine(int dir) {
    _sink.write(
      dir < 0
          ? '\x1B[1K'
          : dir > 0
          ? '\x1B[0K'
          : '\x1B[2K',
    );
  }

  @override
  void cursorTo(int column) {
    _sink.write('\x1B[${column + 1}G');
  }
}

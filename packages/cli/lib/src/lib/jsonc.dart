import 'dart:convert';

import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/filesystem.dart';

/// Strips single-line (//) and block (/* */) comments from a JSONC string.
/// Uses a state machine to avoid stripping comment-like sequences inside
/// string literals.
String stripJsoncComments(String input) {
  final result = StringBuffer();
  var i = 0;

  while (i < input.length) {
    final char = input[i];

    // String literal — pass through verbatim, handling escape sequences
    if (char == '"') {
      result.write(char);
      i++;
      while (i < input.length) {
        final c = input[i];
        result.write(c);
        if (c == r'\') {
          i++;
          if (i < input.length) {
            result.write(input[i]);
            i++;
          }
          continue;
        }
        i++;
        if (c == '"') break;
      }
      continue;
    }

    // Single-line comment: skip until end of line
    if (char == '/' && i + 1 < input.length && input[i + 1] == '/') {
      while (i < input.length && input[i] != '\n') {
        i++;
      }
      continue;
    }

    // Block comment: skip until */, preserving newlines for line numbers
    if (char == '/' && i + 1 < input.length && input[i + 1] == '*') {
      i += 2;
      while (i < input.length) {
        if (input[i] == '*' && i + 1 < input.length && input[i + 1] == '/') {
          i += 2;
          break;
        }
        if (input[i] == '\n') {
          result.write('\n');
        }
        i++;
      }
      continue;
    }

    result.write(char);
    i++;
  }

  return result.toString();
}

Object? parseJsonc(String input) {
  return jsonDecode(stripJsoncComments(input));
}

Future<String> validateJsoncConfigPath(String preferredPath) async {
  if (preferredPath.endsWith('.jsonc')) {
    final jsonPath = preferredPath.substring(
      0,
      preferredPath.length - 1,
    ); // .jsonc → .json
    if (await pathExists(jsonPath)) {
      throw DotweaveError(
        'Unsupported dotweave config file.',
        code: 'CONFIG_JSON_UNSUPPORTED',
        details: [
          'Unsupported config file: $jsonPath',
          'Supported config file: $preferredPath',
        ],
      );
    }
  }

  return preferredPath;
}

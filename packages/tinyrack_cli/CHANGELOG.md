# Changelog

## 0.1.0

- Initial extraction from the dotweave CLI, where this code has been in
  production use.
- `package:tinyrack_cli/tinyrack_cli.dart`: command and route-map builders,
  flag and positional parameters, argument scanning with kebab/camel aliasing
  and did-you-mean suggestions, help rendering, structured exit codes, and
  completion proposals.
- `package:tinyrack_cli/terminal.dart`: levelled logger, TTY-aware spinner, and
  a colour theme honouring `NO_COLOR`, `FORCE_COLOR`, and `CI`.
- Environment access goes through an injectable `EnvLookup` rather than a
  global, so consumers can supply their own view of the environment.

Not published; the API is expected to change before 1.0.

# Configuration

Shipworld reads `shipworld.yaml` from the current directory unless `--config`
selects another file. The configuration uses schema version 1. The canonical
machine-readable contract is
[`schema/shipworld.schema.json`](../schema/shipworld.schema.json).

```yaml
schema: 1
remote: origin
batch-commit: "release: {targets}"

targets:
  example:
    kind: flutter-application
    root: apps/example
    version:
      source: pubspec.yaml
      synchronized:
        - type: dart-constant
          path: lib/src/version.g.dart
          constant: packageVersion
    changelog: CHANGELOG.md
    tag: "example-v{version}"
    commit: "release: example {version}"
    branch: main
    payload:
      kind: directory
      launcher: Contents/MacOS/example
    product:
      name: example
      display-name: Example
      description: Example desktop application
      executable: example
      homepage: https://example.com
      repository: example/example
```

Paths are resolved inside the repository containing `shipworld.yaml`.
Version, changelog, synchronized writer, and payload launcher paths cannot
escape their configured boundary. Unknown fields and unsupported schema
versions are rejected before an operation starts.

`pub-package` and `cli-application` versions are bumped as normal semantic
versions. `flutter-application` also increments the numeric `+build` value.
The tag always receives the core version without build metadata.

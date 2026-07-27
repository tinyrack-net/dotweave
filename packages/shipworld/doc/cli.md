# CLI reference

Install a published release with:

```console
dart pub global activate shipworld
```

All commands accept `--config`, defaulting to `shipworld.yaml`.

```console
shipworld release prepare package_a=patch package_b=minor
shipworld release finalize package_a package_b --push
shipworld release verify package_a

shipworld package windows msix app --input build/windows \
  --output dist/app.msix --package-root .shipworld/msix --arch x64
shipworld package windows bundle app --package-dir dist \
  --output dist/app.msixbundle --working-directory .shipworld/bundle
shipworld package macos sign app --input build/App.app --app-bundle
shipworld package macos archive app --input build/App.app --output dist/App.zip
shipworld package linux appimage app --input build/linux \
  --output dist/App.AppImage --arch x86_64 --tool /usr/local/bin/appimagetool
shipworld package homebrew formula app --artifacts-dir dist \
  --output dist/app.rb --versioned-output dist/app@1.2.3.rb
shipworld package homebrew cask app --archive dist/App.zip \
  --url https://example.com/App.zip --output dist/app.rb
```

Shipworld never downloads signing or packaging tools. Windows SDK tools,
`codesign`, `xcrun`, `ditto`, and `appimagetool` must be installed by the
caller or CI environment. Credential values are read from the environment
names declared in the target configuration.

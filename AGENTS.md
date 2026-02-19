This project is using Haskell `stack` toolchain.
- Cabal files are auto-generated. Only make changes to `packgage.yaml`.
- Use `stack build` to build the library component in `src/`.
- Use `stack test` to build and run tests in `test/`.
- Use `stack run` to build and run the application in `app/`.

Avoid the `String` types.
- Use `Text` instead.

Use modern Haskell.
- Keep the extensions in `package.yaml`.
- Some of the `default-extensions` affecting syntax and code style:
  - ApplicativeDo
  - BlockArguments
  - DerivingStrategies
  - DerivingVia
  - DuplicateRecordFields
  - ImportQualifiedPost
  - LambdaCase
  - NamedFieldPuns
  - OverloadedRecordDot
  - OverloadedStrings
  - RecordWildCards
  - StrictData

Code style
- 2 spaces.
- no horizontal "alignment".

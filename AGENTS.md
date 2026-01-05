# Repository Guidelines

## Project Structure & Module Organization

- `BetterSiri/` is the Swift Package Manager project (see `BetterSiri/Package.swift`).
- `BetterSiri/Sources/` contains the app modules:
  - `App/` and `Coordinator/` for app lifecycle and state.
  - `Chat/`, `Panel/`, and `Settings/` for SwiftUI views.
  - `Services/` for screen capture and OpenRouter networking.
  - `Utilities/` for shared helpers; `Resources/Info.plist` for bundle metadata.
- `BetterSiri.app/` is a built artifact created by `build.sh` (do not edit by hand).

## Build, Test, and Development Commands

```bash
./build.sh
```
Builds a release binary and assembles `BetterSiri.app` in the repo root.

```bash
cd BetterSiri
swift build
swift run
```
Builds and runs the app from SwiftPM for local development.

```bash
cd BetterSiri
swift build -c release
```
Builds a release binary without packaging the app bundle.

```bash
open BetterSiri.app
```
Launches the built app.

## Coding Style & Naming Conventions

- Use standard Swift formatting (4-space indentation) and follow existing SwiftUI patterns.
- Name SwiftUI views with a `View` suffix (e.g., `ChatInputView`) and services with `Service` (e.g., `ScreenCaptureService`).
- Keep files in the matching feature folder under `BetterSiri/Sources/` and align type names with filenames.

## Testing Guidelines

- There is no `Tests/` directory yet and no automated test target configured.
- If you add tests, follow SwiftPM defaults: `Tests/BetterSiriTests` with `swift test` as the entry point.
- Name test types `*Tests` and keep test files colocated with their target.

## Commit & Pull Request Guidelines

- Git history currently contains a single message: `Initial commit: Cluely macOS AI assistant`. There is no established convention yet.
- Prefer short, imperative subjects and include scope when useful (example: `Chat: handle streaming errors`).
- PRs should include a concise summary, testing notes, and screenshots or GIFs for UI changes (panel, settings, or chat).

## Security & Configuration Tips

- OpenRouter credentials are stored via `@AppStorage` keys (for example `openrouter_apiKey`); never commit secrets.
- Document any new permissions (Screen Recording, Accessibility) in README updates when behavior changes.

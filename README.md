# Better Siri

A macOS AI assistant that captures your screen and answers questions about what you see.

## Features

- **Global Hotkey**: Press `⌘ + .` from anywhere to trigger the assistant
- **Screen Capture**: Automatically captures the display under your cursor
- **Floating Glass Panel**: Beautiful Liquid Glass UI (macOS 26) that stays on top
- **Streaming Responses**: Real-time AI responses via OpenRouter
- **Multi-line Input**: Auto-expanding input field (up to 3 lines)
- **Configurable**: Change hotkey and API keys in Settings
- **Browser Automation (Experimental)**: Optional Browser Use integration for autonomous Chrome control

## Requirements

- macOS 15.0+ (Sequoia or later)
- Xcode Command Line Tools
- OpenRouter API key ([get one here](https://openrouter.ai/keys))

## Installation

### Build from Source

```bash
./build.sh
```

This creates `BetterSiri.app` in the project directory.

### Run

Double-click `BetterSiri.app` in Finder, or:

```bash
open BetterSiri.app
```

## Setup

1. **Launch the app** - A sparkle icon appears in your menubar
2. **Open Settings** - Click the menubar icon → Settings (or `⌘ + ,`)
3. **Configure**:
   - Enter your **OpenRouter API key**
   - Model is fixed to **`google/gemini-3-flash-preview`**
   - Optionally change the **hotkey**
   - (Optional) Add a **Browser Use API key** to enable browser automation
4. **Grant Screen Recording Permission** - Press `⌘ + .` and follow the prompt

## Usage

| Action | Shortcut |
|--------|----------|
| Open/Close Panel | `⌘ + .` (configurable) |
| Send Message | `Enter` |
| New Line | `Shift + Enter` |
| Close Panel | `Esc` |

### How It Works

1. Press the hotkey anywhere on your Mac
2. Better Siri captures your current screen
3. A floating panel appears at your cursor
4. Type your question and press Enter
5. The AI analyzes your screen and responds

The panel:
- Stays on top of all windows
- Can be dragged anywhere
- Auto-expands as content grows
- Clicking outside does NOT close it

## Browser Automation (Experimental)

Better Siri can optionally run autonomous browser tasks using the open-source `browser-use` library.

Setup (local dev):

```bash
python3 -m venv .venv-browser-agent
source .venv-browser-agent/bin/activate
pip install -U browser-use
browser-use install
```

Then:

- Settings → Browser Use → set your API key
- Settings → Browser Use → set "Browser agent Python" to `.venv-browser-agent/bin/python`
- Toggle `Browser` in the assistant panel to enable browser tools (the model will call `browser_run_task` when it needs to interact with a live page)

## OnShape CAD (Experimental)

Better Siri can optionally connect to OnShape via the OnShape REST API (API keys) using a local MCP stdio server.

Setup (local dev):

- Create OnShape API keys (access key + secret key)
- Settings → OnShape:
  - set Access Key + Secret Key
  - leave Base URL as `https://cad.onshape.com/api` (or your enterprise URL)
  - leave API Version as `v13` unless you know you need another version

Then:

- Toggle the cube icon (`OnShape`) in the assistant panel
- Provide an OnShape document/Part Studio URL, and ask it to list elements/features, update variables, or run FeatureScript

## Gemini Tools

Since the app is pinned to `google/gemini-3-flash-preview`, you can optionally enable Gemini-native tools in Settings:

- URL context (lets Gemini fetch and read URLs you mention)
- Code execution (lets Gemini run code to verify calculations)

## Project Structure

```
.
├── BetterSiri.app/          # Built application bundle
├── build.sh                 # Build script
└── BetterSiri/              # Source code
    ├── Package.swift
    └── Sources/
        ├── App/             # Main app, menubar
        ├── Coordinator/     # State management
        ├── Services/        # Screen capture, OpenRouter API
        ├── Settings/        # Settings UI
        ├── Panel/           # Floating panel window
        ├── Chat/            # Chat UI components
        └── Utilities/       # Helpers
```

## Supported Models

Any vision-capable model on OpenRouter works. Some examples:

This app is currently pinned to:

- `google/gemini-3-flash-preview`

## Troubleshooting

### Screen Recording Permission

If the capture fails:
1. Go to **System Settings → Privacy & Security → Screen Recording**
2. Find **Better Siri** and toggle it ON
3. Restart Better Siri

### App Won't Quit

Click the menubar icon → Quit, or:
```bash
pkill BetterSiri
```

### Hotkey Not Working

1. Check System Settings → Privacy & Security → Accessibility
2. Ensure Better Siri has permission (may not be needed)
3. Try setting a different hotkey in Settings

## Development

### Build Debug Version

```bash
cd BetterSiri
swift build
swift run
```

### Build Release Version

```bash
cd BetterSiri
swift build -c release
```

## License

MIT

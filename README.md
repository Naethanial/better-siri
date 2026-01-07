# Better Siri

A macOS AI assistant that captures your screen and answers questions about what you see.

## Features

- **Global Hotkey**: Press `⌘ + .` from anywhere to trigger the assistant
- **Screen Capture**: Automatically captures the display under your cursor
- **Floating Glass Panel**: Beautiful Liquid Glass UI (macOS 26) that stays on top
- **Streaming Responses**: Real-time AI responses via OpenRouter
- **Browser Agent (Experimental)**: Auto-detects browser tasks (or use `/browser …`) via `browser-use` (Chrome automation)
- **Multi-line Input**: Auto-expanding input field (up to 3 lines)
- **Configurable**: Change hotkey, model, and API key in Settings

## Requirements

- macOS 15.0+ (Sequoia or later)
- Xcode Command Line Tools
- OpenRouter API key ([get one here](https://openrouter.ai/keys))
- Optional (for Browser Agent): Python 3.11+ with `browser-use` installed

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
   - Choose a **model** (default: `google/gemini-3-flash-preview`)
   - Optionally change the **hotkey**
4. **Grant Screen Recording Permission** - Press `⌘ + .` and follow the prompt

## Usage

| Action | Shortcut |
|--------|----------|
| Open/Close Panel | `⌘ + .` (configurable) |
| Send Message | `Enter` |
| New Line | `Shift + Enter` |
| Close Panel | `Esc` |
| Stop streaming | Click the red stop button |
| Run browser task (experimental) | Ask normally (auto), or `/browser <task>` |

### Browser Agent (Experimental)

The browser agent runs a local `browser-use` agent that controls a dedicated automation Chrome profile (cookies/sessions live in that shared window).

Browser tasks run in a shared Chrome window (no new window per task).

1. Open Settings → **Browser Agent (browser-use)** and enable it.
2. Ensure `python3` is available and `browser-use` is installed:
   - Recommended: follow https://docs.browser-use.com/quickstart (installs `browser-use` + browser dependencies)
3. Click **Start Browser Window** (or ask “open the browser window”).
4. Ask a task like:
   - `Visit https://duckduckgo.com and search for "browser-use founders"`
   - Or force browser mode: `/browser Visit https://duckduckgo.com and search for "browser-use founders"`

Tip: Enable **Keep browser open between tasks** in Settings to keep an automation Chrome window open so future browser tasks can reuse it.

If you want to co-navigate (use the same Chrome window yourself while the agent drives it), enable **Attach to existing Chrome (don’t launch)** and start Chrome with remote debugging enabled (Chrome requires a non-default `--user-data-dir`):

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222 --user-data-dir="$HOME/Library/Application Support/BetterSiri/Chrome"
```

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

- `google/gemini-3-flash-preview` (default)
- `anthropic/claude-sonnet-4`
- `openai/gpt-4o`
- `google/gemini-2.0-flash-exp`
- `anthropic/claude-3.5-sonnet`

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

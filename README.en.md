# Notch Island

[繁體中文](README.md) · English

![Notch Island icon](docs/notch-island-icon.png)

Notch Island is a macOS menu bar app built with Swift, AppKit, and SwiftUI. It turns the area around a MacBook's camera notch into an interactive island for music, timers, and widgets. The interface is available in English, Traditional Chinese, and Simplified Chinese.

This project is inspired by the iPhone Dynamic Island. It does not receive iPhone Live Activities or arbitrary third-party notifications: the activities shown are the ones supported by the app itself.

## Features

- **Notch-aware layout:** measures the display's safe areas and adjusts to the reported notch geometry. Inactive widgets stay below the menu bar; active music and timers can use the spaces beside the notch.
- **Quick access:** click the activation area to expand immediately, or hover for one second. Switch between active activities and widgets when activities are running.
- **Music and timers:** view supported media and control playback, run a countdown, or use the stopwatch. Some browser and system media controls require additional setup or permissions.
- **Widgets:** choose and reorder up to four widgets, including battery, weather, stocks, timer, stopwatch, calendar, and clock. Weather and stock features use network services; calendar and location require permission.
- **Quick actions:** clipboard history with a configurable retention period, screenshot to clipboard, and a screen-recording entry point.
- **Music recognition:** ShazamKit, an optional attempt to invoke macOS Control Center's Recognize Music, and an opt-in third-party AudD option. See the limitations below before relying on these features.
- **Onboarding and settings:** choose a language and review permissions when first setting up the app.

## Requirements

- macOS 14 Sonoma or later.
- A notched MacBook is the intended device. Layout is derived from the display's reported safe areas; other models have not all been tested on physical hardware.
- Xcode or Apple Command Line Tools to build the project. Some features require newer macOS versions or additional permissions.

## Build and run

```bash
./build.sh
open build/NotchIsland.app
```

To build a universal app containing Apple silicon and Intel slices, run `./build.sh --universal`. The app appears in the menu bar rather than the Dock. To build a DMG locally:

```bash
python3 -m venv build/dmg-tools
build/dmg-tools/bin/python -m pip install -r scripts/dmg-requirements.txt
scripts/make_dmg.sh
```

The DMG is created in `dist/`. These instructions create an ad-hoc signed build by default; it is not notarized. macOS may warn or block it on first launch, and privacy grants may need to be renewed after rebuilding. See [Apple's guidance for opening software safely](https://support.apple.com/en-us/102445) and the detailed [Traditional Chinese README](README.md) for optional Developer ID signing and notarization instructions.

## Permissions and privacy

Permissions are requested or explained when relevant. Depending on the features you choose, macOS may ask for Accessibility, Input Monitoring, screen and system audio recording, microphone, notifications, location, calendar, or Automation access. Clipboard history is stored locally and has a configurable retention period.

Weather and stock widgets contact their respective providers when enabled. API keys entered by the user are stored in the macOS Keychain rather than in the project. The optional AudD service requires your own API token and explicit consent before recording a short audio sample and sending it to AudD; check its current trial and pricing terms before use. No AudD key is included with the project.

## Music recognition and current limitations

- Apple requires ShazamKit to be enabled for an app's registered App ID to use the Shazam music catalog. An ad-hoc build on the development Mac returned error 202; successful catalog recognition has not been verified for this build. See [Apple's ShazamKit documentation](https://developer.apple.com/shazamkit/).
- The Control Center option attempts to press macOS's Recognize Music controls using Accessibility. It requires Accessibility permission and the control to be added to Control Center. The result appears in Control Center, not in the island. This path has not yet been tested on an unlocked desktop and may vary across macOS releases.
- AudD's request flow was tested with synthetic audio and mocked network responses, not with a real token or live recognition. The service has a limited trial and paid options; consult [AudD pricing](https://audd.io/pricing/).
- Screenshot, recording, and recognition UI flows need further testing on an unlocked Mac. Other notched MacBook models and the Intel slice have not been comprehensively tested on physical devices.
- Media controls and browser integration depend on the player, macOS permissions, and the browser's configuration; they may not work with every app.

## Tests

```bash
Tests/run_tests.sh
```

The offline tests cover geometry, localization, widgets, quick-action decisions, and mocked recognition flows. `Tests/run_tests.sh --live` additionally makes read-only requests to supported weather and stock services.

## Project layout

- `Sources/NotchIsland/` — app, UI, integrations, and providers.
- `Resources/` — app icon, property list, entitlements, and localized usage descriptions.
- `Tests/` — offline tests and preview rendering helpers.
- `scripts/` — icon artwork, DMG packaging, and privacy scanning tools.

Before sharing the project, review the files and Git history yourself. `python3 -I scripts/secret_scan.py` can flag common secret patterns and personal media, but it is a heuristic and cannot guarantee that the project contains no sensitive data. The repository does not include personal screenshots, recordings, local handoff notes, build products, or DMGs.

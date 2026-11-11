# Notch Island

[繁體中文](README.md) · English

Turn your MacBook notch into a quick place for music, timers, and widgets. Notch Island adapts to the notch dimensions reported by your display and supports English, Traditional Chinese, and Simplified Chinese.

<p align="center"><img src="docs/images/compact-v0.1.1.jpg" width="440" alt="Collapsed island"></p>
<p align="center"><img src="docs/images/now-playing-en-v0.1.1.jpg" width="560" alt="Now playing"></p>
<p align="center"><img src="docs/images/widgets-en-v0.1.1.jpg" width="560" alt="Widgets"></p>

## Features

- **Notch interaction:** click to expand immediately or hover for one second. When idle, the menu bar beside the notch stays clear.
- **Music and activities:** see artwork, track details, and playback progress for supported sources; control playback and seeking. Countdowns and stopwatches appear while active.
- **Widgets:** choose and arrange up to four widgets, including battery, weather, stocks, clock, calendar, timer, and stopwatch. Switch between activities and widgets when something is active.
- **Quick actions:** clipboard history, screenshot to clipboard, screen recording, and music recognition (Song Finder by default).
- **Software update:** check GitHub for the latest release on demand, verify the download's SHA-256, and follow a guided install.
- **Power alerts:** see charging status when power is connected and a low-battery reminder with a shortcut to macOS Battery settings.

## Installation

Requires macOS 14 Sonoma or later. Designed for MacBook models with a notch.

1. Visit [Latest Release](https://github.com/LeoFeng0816/Notch-Island/releases/latest) and download `NotchIsland-*.dmg`.
2. Open the DMG, drag **Notch Island** to **Applications**, then eject the DMG.
3. Open Notch Island from Applications. If macOS displays a verification warning, dismiss it with **Done** or **OK**; do not move the app to the Trash.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, and choose **Open Anyway** next to Notch Island. Follow the confirmation prompts. The button is usually available for about an hour after the launch attempt.
5. Complete the first-launch setup. Afterwards, open settings from the Notch Island menu-bar icon.

The app is ad-hoc signed and **not notarized by Apple**. Only if you trust the download, follow [Apple's instructions](https://support.apple.com/en-us/102445) to allow this app individually; you do not need to disable Gatekeeper.

## Using Notch Island

- **Music:** play media from a supported source and expand the island to view and control it. Configure Apple Music, Spotify, and optional YouTube / YouTube Music integration in settings. Browser integration may need Automation permission and browser configuration.
- **Widgets:** select, reorder, or disable widgets in settings; up to four can be shown at once. Weather can use your current location, and stocks can be searched by company or ticker.
- **Clipboard:** choose whether to keep history and for how long. Select an item to copy it; automatic paste can be attempted after granting permission to send keystrokes.
- **Screenshots and recording:** screenshots are copied to the clipboard. Recording opens the native macOS recording toolbar, where you start the recording.
- **Music recognition:** uses [Song Finder](https://songfinder.dev) by default, with no account or API key. The first press explains where the audio goes and asks for your consent. A match shows the title and artist, with **Google Search** (artist and title prefilled) and **Copy** (“Artist - Title”). “No match” is shown only when Song Finder says nothing matched; permissions, connectivity, timeouts, rate limits and server errors are reported separately. In settings you can switch to macOS Recognize Music (results stay in Control Center) or AudD (your own API token).
- **Software update:** use **Check for Updates…** in the menu bar or **Settings › Software Update**. If a newer stable release exists, its version and notes are shown and you can **Download and Verify**: the file's size and SHA-256 must match what GitHub lists, it is saved to Downloads, and macOS's quarantine flag is kept. The app never installs or replaces itself. Use **Back Up Current App** first, then follow the on-screen steps to drag it into Applications (choose **Keep Both** to keep the old copy too). Settings, clipboard history and Keychain items are kept; permissions may need to be granted again. A matching checksum only shows the file is the one attached to the GitHub release; it is not Apple verification. New versions are also unnotarized, so allow them as described in Installation.

## Privacy and permissions

Notch Island has no servers of its own. System permissions support the features you choose; clipboard history is stored locally, and calendar data is not transmitted by the app.

**Music recognition (Song Finder, the default) sends audio off this Mac.** The first time you press Music Recognition, a disclosure is shown and nothing is recorded until you agree. After that, each press records about 12 seconds from the microphone and this Mac's sound output (each only if available and allowed by macOS), mixes them into one clip in memory, uploads it once over HTTPS to the third-party service Song Finder (songfinder.dev), and then discards it; nothing is written to disk. The clip contains anything audible, such as nearby voices. According to Song Finder's [privacy policy](https://songfinder.dev/privacy-policy) (updated 2026-08-25), the clip goes to its configured recognition providers (currently ACRCloud, AudioTag and Shazam) and is not retained after recognition; that is Song Finder's statement, which Notch Island cannot verify. Recording and uploading stop when the island closes. You can withdraw consent or choose another method in settings.

Other optional online features: weather sends a city or approximate location to Open-Meteo, and stocks send ticker queries to the quote provider. AudD uploads up to 10 seconds of audio only with your own API key and consent; keys are stored in the macOS Keychain. macOS Recognize Music runs in Control Center under Apple's privacy terms. Checking for updates contacts api.github.com only when you click, and downloads come from GitHub's release files.

When relevant, the app explains permissions for Accessibility, screen and system audio recording, microphone, location, calendar, or Automation. macOS may require permissions to be granted again after updating an ad-hoc build.

## Build from source

With Xcode or Apple Command Line Tools installed, run from the project root:

```bash
./build.sh
open build/NotchIsland.app
```

Run offline tests with `Tests/run_tests.sh`; the DMG packaging script is `scripts/make_dmg.sh`. The app lives in the menu bar rather than the Dock, where you can open settings or quit.

## Donation

If you enjoy Notch Island, you are welcome to support the project. Thank you!

[![Donate with PayPal](https://img.shields.io/badge/PayPal-Donate-003087?style=for-the-badge&logo=paypal&logoColor=white)](https://www.paypal.com/ncp/payment/UY8JAHZCRVDLY)

**Cryptocurrency**

- Stablecoins (USDT, USDC, PYUSD; Solana network): `BCyMirZrcGhcKUonkhykfnUq5pQbeUbXgCQmwJQfjy1o`
- Solana (Solana network): `BnE2VfdgKE2aubg9YpJuPSTFpFgbMawaqcbxXJkff2kL`
- Ethereum (Ethereum network): `0xa8d689b94a54414362b2bd0e6f0cb2a74651f4b0`
- Bitcoin (BTC Taproot): `bc1panr25wetvhl2kyxquu3re6ts4pw6g7fwdul8hpv4shaqu7g9qhyq68twql`

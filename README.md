# PasteHub

![PasteHub — Your clipboard, a shortcut away. Blue clipboard artwork with the Control and V keys.](docs/assets/pastehub-cover.png)

A lightweight clipboard history app for macOS. Copy text, links, and images as usual. Press **Control + V** to find something you copied earlier and paste it into the app you're using.

[Download for Mac](https://github.com/caork/PasteHub/releases/latest/download/PasteHub.app.zip) · [Release notes](https://github.com/caork/PasteHub/releases) · [Report an issue](https://github.com/caork/PasteHub/issues)

## Get started

### 1. Install PasteHub

Download `PasteHub.app.zip`, unzip it, and drag **PasteHub.app into Applications**. Open it from there.

The current download requires **Apple Silicon (M1 or later) and macOS 14 or later**. The native app icon adapts to the appearances supported by your macOS version.

PasteHub lives in the **menu bar**. It does not keep a Dock icon open. Click its clipboard icon to open your history, access settings, or quit.

> The current release is not notarized by Apple, so macOS may show a security prompt on first launch. Download it only from this repository's Releases page.

### 2. Enable automatic pasting

The current app interface is in Chinese; this guide describes its controls in English.

In PasteHub settings, open the permissions section and use the button to open System Settings. Enable PasteHub in the system permission list, then return to PasteHub and check the permission status again.

The system path is **System Settings → Privacy & Security → Accessibility**. On newer macOS versions, the page may be called **Device Control and Data Access**. The button inside PasteHub takes you directly to the relevant page.

This permission lets PasteHub paste your selection into the active app. Without it, selecting a history item still copies it to your clipboard; press **Command + V** to paste manually.

### 3. Copy, find, paste

1. **Copy as usual.** Press **Command + C** to copy text, a link, or an image. PasteHub saves supported clipboard content while it is running.
2. **Open your history.** Place the cursor where you want to paste, then press **Control + V**.
3. **Choose an item.** Click it, or select it with **↑ / ↓** and press **Return**. PasteHub pastes it at your cursor.

Type in the history panel to search. To paste text without its original formatting, press **Shift + Return**.

## Everyday shortcuts

Except for opening history, these shortcuts work inside the history panel.

| Action | Shortcut |
| --- | --- |
| Open clipboard history | **Control + V** — customizable in settings |
| Select an item | **↑ / ↓** |
| Paste the selected item | **Return**, or click the item |
| Paste a text item without formatting | **Shift + Return** |
| Paste one of the first nine visible items | **Command + 1…9** |
| Paste one of those items as plain text | **Command + Shift + 1…9** |
| Pin or unpin the selected item | **Command + P** |
| Delete the selected item | **Command + Delete**, or **Delete** when search is empty |
| Close history | **Esc**, or click outside the panel |

Pin snippets you use often to keep them handy. Unpinning an item does not immediately delete it.

## Make it yours

Open settings from the menu bar icon to adjust:

- **History shortcut:** choose a combination that works with your other apps.
- **Launch at login:** start PasteHub when you sign in to your Mac.
- **History limit:** keep 20–1,000 unpinned items; the default is 200.
- **Clear unpinned history on quit:** optional and off by default.
- **Skip verification codes / OTPs:** rule-based filtering, enabled by default.
- **Check for updates:** find new releases on GitHub and choose when to install them.

## Your history stays on your Mac

PasteHub stores clipboard history locally. **No account, no cloud sync, and no upload of your clipboard history.** Checking for updates connects to GitHub.

It excludes apps such as 1Password, Bitwarden, KeePassXC, LastPass, Passwords, and Authy by default. Verification-code filtering uses heuristics and cannot catch every sensitive item. Delete individual records when needed, or clear all history in settings.

Supported content includes plain text, links, RTF / HTML rich text, and images. Formatting depends on the destination app. Text larger than 1 MiB and images larger than 10 MiB after conversion are skipped.

## Troubleshooting

**I opened PasteHub, but there is no window.**

PasteHub is a menu bar app. Press **Control + V** or click its menu bar icon to open history.

**Selecting an item copies it, but does not paste it.**

Check the permission status in PasteHub settings. Use the app's button to open System Settings and enable its Accessibility permission. You can also paste the selected item manually with **Command + V**.

**The system toggle is on, but PasteHub says permission is missing.**

An upgrade or a newly signed build can leave an old permission entry behind. Quit and reopen PasteHub first. If that does not help, remove its old entry from the system permission list, then use **+** to add `/Applications/PasteHub.app` again. Return to PasteHub and recheck the status.

**Something I copied is missing from history.**

Check whether its source app is excluded, whether the verification-code filter matched it, or whether it exceeded the size limit. PasteHub only captures content copied while it is running.

**The history shortcut does nothing.**

Make sure PasteHub is running. Try a different shortcut in settings if another app uses the same combination.

Still stuck? [Open an issue](https://github.com/caork/PasteHub/issues) with your macOS version, PasteHub version, destination app, and steps to reproduce the problem.

## Build from source

Install full Xcode, including Swift and the Icon Composer asset tools, then run:

```bash
git clone https://github.com/caork/PasteHub.git
cd PasteHub
make test
make build CONFIG=release
```

The build script creates `dist/PasteHub.app` and installs it into `/Applications/PasteHub.app` by default. To build without installing:

```bash
SKIP_INSTALL=1 zsh Scripts/build-app.sh release
```

Without a suitable developer signing identity, local builds use ad-hoc signing. You may need to refresh the Accessibility permission after rebuilding.

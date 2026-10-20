<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Dropovr icon">
</p>

<h1 align="center">Dropovr</h1>

<p align="center">
  <b>A free, fast floating drop shelf for macOS. Made for the Mac community.</b><br>
  Shake your mouse while dragging, drop anything onto the shelf, then drag it out wherever you need it.<br>
  You can even send files to and from your phone with a QR code.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-native-orange?logo=swift">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Free forever" src="https://img.shields.io/badge/price-free%20forever-brightgreen">
  <img alt="No ads" src="https://img.shields.io/badge/ads-none-brightgreen">
</p>

<p align="center">
  <b>100% free · No ads · No subscription · No account · No tracking · Open source</b>
</p>

---

## Why Dropovr?

Moving files between windows, Spaces and apps on a Mac often means juggling two Finder windows.
Dropovr gives you a temporary shelf that floats above everything. Park files on it, switch to where
they need to go, and drag them out.

Shelf apps are usually paid or subscription-based. Dropovr is a clean, community-made alternative:

- **Free forever.** Every feature is included. There's no "Pro" version, trial or paywall.
- **No ads, no tracking, no analytics.** Dropovr never contacts the internet. The optional phone feature talks only to devices on your own Wi‑Fi.
- **No account.** Install it and use it.
- **Open source (MIT).** Read every line, build it yourself, change it and share it.

## Features

- **Shake to open.** Start dragging anything and shake the mouse left and right. A shelf pops up under your cursor.
- **Works with almost anything.** Files, folders, photos from the Photos app, images from Safari or Mail, text, rich text, PDFs and web links.
- **Real previews.** Photos, videos, PDFs, Office and iWork documents, and anything else Quick Look can preview.
- **Stack or grid.** Items fan out as a stack of cards. Drag the stack to move everything, or click it to browse a grid and drag single items.
- **Send to your phone.** Scan a QR code with any iPhone or Android phone on the same Wi‑Fi to download shelf items or send files back to the Mac. No app or account needed.
- **AirDrop and Share.** Send items straight from the shelf.
- **Handy actions.** Quick Look, copy, compress to ZIP, save to Downloads and show in Finder.
- **Multiple shelves.** Open as many as you like. Each one floats on every Space and over full-screen apps.
- **Always-on phone link.** Turn it on in Settings and add Dropovr to your iPhone or Android Home Screen. It opens like an app whenever your Mac is awake and on the same Wi‑Fi.
- **Settings.** Shake sensitivity, the <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> shortcut, glass darkness, what happens after you drag items out, and open at login.
- **Native and light.** Pure Swift and AppKit, with no Electron, no tracking and no network access except the phone feature you turn on.

## Install

Dropovr is built from source. It takes about a minute and needs Apple's free command-line tools.

```bash
xcode-select --install          # skip if you already have them
git clone https://github.com/pgsohail/dropovr.git
cd stash
./build.sh --install
```

This builds `Dropovr.app`, copies it to `/Applications` and opens it. Its icon appears in your
menu bar. Because the app is built on your own Mac, macOS doesn't show the "unidentified developer"
warning.

To make Dropovr start when you log in, open **Settings** (menu bar icon → Settings…, or <kbd>⌘</kbd> <kbd>,</kbd>) → **Open Dropovr at login**.

## How to use

| Do this | To |
|---|---|
| Shake the mouse while dragging | Open a shelf at your cursor |
| <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>S</kbd> anywhere | Open a shelf |
| Menu bar icon → **New Shelf** | Open a shelf |
| Menu bar icon → **Settings…** | Shake sensitivity, shortcut, darkness, phone link |
| Right-click a file → **Open With → Dropovr** | Put that file on a shelf |
| Drag the stack out | Move everything |
| Click the stack | Browse items in a grid |
| <kbd>Space</kbd> | Quick Look |
| <kbd>⌘</kbd> <kbd>C</kbd> | Copy items |
| <kbd>⌘</kbd> <kbd>A</kbd> | Select all |
| <kbd>Delete</kbd> | Remove selected items from the shelf (the files themselves stay put) |
| <kbd>Esc</kbd> | Go back, or close the shelf |

**Moving and copying.** Items you *move* somewhere, such as into another folder on the same disk,
leave the shelf. Items you *copy* somewhere, such as when uploading to a website or copying to
another disk, stay on the shelf so you can use them again.

### Phone sharing

1. Click the 📱 button on a shelf.
2. Scan the QR code with your phone's camera.
3. Tap an item to download it to your phone, or tap **Send to Mac** to upload photos and files onto the shelf.
4. Click **Stop Sharing** when you're done.

**Always-on link:** in **Settings → Phone**, turn on **Always-on phone link**. You get one permanent link that
uses your Mac's name (for example `http://My-Mac.local:47777/…`), so it keeps working when your router
gives the Mac a new address. Open it on your phone and choose **Share → Add to Home Screen** (iPhone) or
**⋮ → Add to Home screen** (Android). Files you send from the phone open a shelf on the Mac automatically.
Use **New Link** in Settings any time to cut off phones using the old one.

The phone and Mac must be on the same Wi‑Fi. Dropovr runs a small private web server only while
sharing is on. Each session gets a new random link, so only someone who scans your code can connect.
Folders download as ZIP files. The first time, macOS may ask to let Dropovr use the local network.

## Supported content

| Dropped content | Saved on the shelf as |
|---|---|
| Any file, folder, app or package | The original item (nothing is copied) |
| Photos from Photos, Mail attachments, Safari images | The real file, delivered by the app |
| Images from other apps | `.png` |
| Selected text | `.txt` |
| Rich text | `.rtf` |
| PDF content | `.pdf` |
| Web links | `.webloc` (double-click to open) |

New files made from snippets live in `~/Library/Caches/Dropovr`.

## Project layout

```
Resources/
  logo.svg          App and menu bar logo
Sources/
  App.swift         Menu bar app, ⌃⌥S shortcut, shake-to-open detection
  Shelf.swift       The shelf window, its actions, keyboard and Quick Look
  Components.swift  Card stack, grid tiles, drop zone, buttons, toasts, drag-out
  Files.swift       Reading drops, snippet files, Quick Look thumbnails
  Phone.swift       Wi‑Fi phone sharing: web server, QR code, mobile page
  Settings.swift    Preferences and the Settings window
make-icon.swift     Draws the app icon
build.sh            Builds (and optionally installs) Dropovr.app
```

## Requirements

- macOS 13 Ventura or later. Built and tested on Apple Silicon.
- Apple's command-line developer tools, to build it.

## Contributing

Dropovr is built by and for the Mac community, and contributions are welcome:

- **Found a bug or have an idea?** [Open an issue](https://github.com/pgsohail/dropovr/issues).
- **Want to fix or build something?** Fork the repo, make your change, run `./build.sh --install` to try it, then open a pull request.
- **Keep it clean.** Dropovr stays free, ad-free and private. Please don't add tracking, ads or anything that phones home.

## Credits

Logo: "Protein" icon from [SVG Repo](https://www.svgrepo.com).

## License

MIT. See [LICENSE](LICENSE).

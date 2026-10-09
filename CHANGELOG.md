# Changelog

Notable changes to AudioPilot. Add entries under **Unreleased** as you go; `scripts/bump-version.sh` turns that
heading into the release version, and the Release workflow publishes the section as the release notes.

## Unreleased

### Added
- Pick the mute and unmute sounds from the macOS system sounds in **Settings › General › Feedback**, with a
  button to hear each one.

### Changed
- Per-app audio captures in a separate helper process that runs only while an app is rerouted, so macOS stops
  listing AudioPilot under System Audio Recording as soon as nothing is (previously it stayed until AudioPilot quit).

## 0.2.1 — 2026-10-08

### Changed
- Per-app audio is now a switch in **Settings › App Audio** and is off by default. While it's off, AudioPilot
  leaves every app alone, hides the panel's **Apps** section and never asks for System Audio Recording permission.
  Setups that already have per-app settings keep it on.

## 0.2.0 — 2026-10-03

### Added
- Per-app audio (macOS 14.2+): give an app its own output device, volume and mute, from the new **Apps**
  section in the panel or **Settings › App Audio**. Needs System Audio Recording permission.
- App rules can trigger while an app is using the mic, or while any app is (**Any App Using the Mic**), so devices
  switch when a call starts rather than when the app opens.
- Optional live input level in the menu bar icon while another app is using the mic.
- Export and import all settings and profiles as a file (**Settings › General › Backup**).
- `--app-audio` and `--test-tap` diagnostics.

### Changed
- The level meter follows the default input when it changes.

## 0.1.1 — 2026-09-27

### Added
- App icon.

## 0.1.0 — 2026-09-27

First release: automatic input and output switching by learned priority, Bluetooth mic blocking, app rules,
profiles that follow Wi-Fi, one-shortcut mute for every mic, command palette, Spotlight and Shortcuts actions, and
`audiopilot://` links.

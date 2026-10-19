# pFlow by Pesh

Native dictation for macOS and Windows. Hold a key, speak, and release to insert text into the field you were using. Speech recognition runs locally through whisper.cpp. No account, subscription, telemetry, or API key is required.

## Downloads

[Download pFlow for Mac or Windows](https://github.com/PESHian/pFlow/releases)

These are testing builds. macOS and Windows may show an unsigned or unnotarized app warning. Only install downloads from this repository and check the supplied SHA-256 file.

| Platform | Download | Requirements |
| --- | --- | --- |
| Mac | pFlow-Mac-0.3.5-testing.dmg | Apple Silicon, macOS 27 or later |
| Windows | pFlow-Windows-Universal-0.1.12-testing.zip | Windows x64 (Intel/AMD), ARM64, or x86; Windows 10 1607+ / Windows 11 |

### Mac

Open the disk image and drag **pFlow by Pesh** into Applications. Open it and grant Microphone, Speech Recognition, Accessibility, and Automation permissions when asked. Hold **Right Command** to record, then release. Double-tap for continuous dictation; tap again to stop. Left Command stays available for shortcuts.

The first use may need a checksum-verified Whisper model download. Apple Intelligence provides cleanup and report formatting when available. If it is unavailable, plain dictation remains available. This testing download is ad-hoc signed and not notarized. If macOS blocks it, use [Apple's Open Anyway steps](https://support.apple.com/en-us/102445) after checking the download.

### Windows

Extract the entire universal ZIP and double-click **Install.cmd**. It detects your native Windows architecture, checks the selected files, and installs the matching build for your user account. Open **pFlow by Pesh** from Start. It runs in the tray; open Settings from its tray menu. In **Settings → Shortcut → Activation key**, choose **Right Ctrl**, **F8–F12**, or **Right Windows**. Hold your chosen key to record, then release. Double-tap within about 300 ms for continuous dictation; tap to stop. Left Windows stays available for shortcuts. The choice is saved; existing installations keep Right Windows until changed.

The Windows download includes the Whisper speech model and .NET runtime. AI cleanup and report formatting use an optional 2.5 GB Qwen text model: choose **Download or repair text model** in Settings if you want those features. Its size and SHA-256 are checked before use. This optional text model requires 64-bit Windows; 32-bit Windows keeps dictation, basic cleanup, dictionary, and full-narrative templates. Basic dictation works without it. After setup, model inference runs offline.

No administrator password, separate .NET installation, or architecture choice is needed. Do not run an EXE copied out of its payload folder. See [full installation instructions](windows/INSTALLATION.txt). Windows 10 builds require version 1607 or later; Microsoft supports .NET 10 on its listed LTSC/Enterprise editions. Windows 7, 8, Windows RT/ARM32, and older releases are unsupported.

Quit pFlow before updating. Turn Mac dictation off before testing Windows recording in a VM on the same Mac.

## Updates

Choose **Check for updates** in the tray/menu bar or Settings, then **Install and restart**. pFlow checks a signed release list and verifies the download before replacing the app. Settings, history, and models stay on your device. Checks run only when requested. Install this updater release once using the steps above; earlier builds cannot update themselves. Published GitHub binary releases become available in the app; source commits alone do not.

Windows on/off controls show **On** or **Off** and a contrasting thumb. Settings shows the latest dictation time split into speech, AI cleanup, report formatting, and insertion when those stages ran. This readout contains no dictated words. AI cleanup remains optional; this release does not claim a processing speed improvement.

## Features

- Compact movable waveform, Wave and Lines styles, Pesh colors, light/dark/system themes.
- Dictionary, user templates, optional bold headings, local history, and daily/per-app statistics.
- Sentence spacing and paragraph boundaries; original text is retained when AI edits fail checks.
- Clipboard-copy can be off while insertion stays enabled. Clipboard restoration avoids replacing a newer copy.
- Password fields are excluded. Focus changes and unsupported fields can prevent insertion; the transcript remains in local history.
- Optional per-user launch at login.

## Privacy

Whisper transcribes audio on your device. Mac AI defaults to on-device processing. Source builds with Apple’s required entitlement can opt into Apple Private Cloud Compute, which sends text and formatting instructions to Apple; the supplied Mac testing download has no cloud entitlement. Windows AI runs locally. Model downloads contact their hosting services. History and settings stay in your user account, outside the app. Delete history entries when they are no longer needed.

This public repository contains application source, artwork, licenses, and fictional test fixtures. It does not include user settings, saved dictations, personal recordings, credentials, private development history, or device access files. The original private development repository has been retained separately.

## Build from source

Mac: install Xcode with the macOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate`, then build the Yap scheme from `Yap.xcodeproj`. `scripts/build-whisper.sh` prepares the pinned local engine. `release.sh` supports Developer ID signing/notarization when you supply your own credentials.

Windows: install .NET 10 SDK, CMake, and Visual Studio C++ tools for your architecture, then run `windows/scripts/build-windows.ps1`. See [Windows details](windows/README.md). Use `-Architecture x64`, `-Architecture arm64`, or `-Architecture x86`. ARM64 native compilation uses the Clang C++ toolset; the other builds use MSVC with a static speech runtime. The published Windows binaries omit debug symbols. Release builds are checked for personal build paths; source builds need the same checks before distribution. Each architecture needs its own build and verification.

## Tested limits

Windows x64 and ARM64 builds have passed native Windows ABI, private clipboard restoration, and saved-audio transcription/reuse checks; x86 passed the same checks under Windows x64 WOW64. A native 32-bit Windows installation and old Windows 10/older CPU hardware remain unverified. Architecture support does not promise support for every historic Windows release or identical speed on all CPUs. The earlier Windows ARM64 build has been exercised on a Windows 11 VM, including saved-audio recognition, Notepad insertion, settings, templates, themes, and statistics. Physical microphone/key behavior, Edge/Electron insertion, and actual login behavior have not all been verified. That VM presented only about 5–6 waveform frames per second; fluid animation there remains unresolved. Speeds vary with hardware, recording length, and optional AI formatting.

Mac and Windows use different AI formatting engines and are not claimed to have identical behavior. The Mac download is not notarized, and the Windows executable is not Authenticode signed.

## License and attribution

pFlow is based on [Yap by Frigade](https://github.com/FrigadeHQ/yap), under the [MIT License](LICENSE). The original copyright and license notice are retained. Pesh artwork and pFlow changes are distributed under the same license. whisper.cpp, its audio/model components, llama.cpp, Qwen, .NET, and Swift dependencies retain their own included licenses. Model downloads must keep their accompanying notices.

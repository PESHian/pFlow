# pFlow by Pesh

Native dictation for macOS and Windows. Hold a key, speak, and release to insert text into the field you were using. Speech recognition runs locally through whisper.cpp. No account, subscription, telemetry, or API key is required.

## Downloads

[Download pFlow for Mac or Windows](https://github.com/PESHian/pFlow/releases)

These are testing builds. macOS and Windows may show an unsigned or unnotarized app warning. Only install downloads from this repository and check the supplied SHA-256 file.

| Platform | Download | Requirements |
| --- | --- | --- |
| Mac | pFlow-Mac-0.3.4-testing.dmg | Apple Silicon, macOS 27 or later |
| Windows | pFlow-Windows-ARM64-0.1.8-testing.zip | Windows 11 ARM64; x64 source builds are available but an x64 release has not been tested |

### Mac

Open the disk image and drag **pFlow by Pesh** into Applications. Open it and grant Microphone, Speech Recognition, Accessibility, and Automation permissions when asked. Hold **Right Command** to record, then release. Double-tap for continuous dictation; tap again to stop. Left Command stays available for shortcuts.

The first use may need a checksum-verified Whisper model download. Apple Intelligence provides cleanup and report formatting when available. If it is unavailable, plain dictation remains available. This testing download is ad-hoc signed and not notarized. If macOS blocks it, use [Apple's Open Anyway steps](https://support.apple.com/en-us/102445) after checking the download.

### Windows

Extract the entire ZIP to a folder you can write to and run **pFlow.exe**. It runs in the tray; open Settings from its tray menu. Hold **Right Windows** to record, then release. Double-tap within about 300 ms for continuous dictation; tap to stop. Left Windows stays available for shortcuts. A VM may map Right Command to Right Windows.

The Windows download includes the Whisper speech model and .NET runtime. AI cleanup and report formatting use an optional 2.5 GB Qwen text model: choose **Download or repair text model** in Settings if you want those features. Its size and SHA-256 are checked before use. Basic dictation works without it. After setup, model inference runs offline.

To install for your Windows user account, open PowerShell in the extracted folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Source .
```

Quit pFlow before updating. Turn Mac dictation off before testing Windows recording in a VM on the same Mac.

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

Windows: install .NET 10 SDK, CMake, and Visual Studio C++ tools for your architecture, then run `windows/scripts/build-windows.ps1`. See [Windows details](windows/README.md). The published Windows binaries omit debug symbols and use Clang to map native source paths. Builds using other native compilers need their own path checks before distribution. Each architecture needs its own build and verification.

## Tested limits

The Windows ARM64 build has been exercised on a Windows 11 VM, including saved-audio recognition, Notepad insertion, settings, templates, themes, and statistics. Physical microphone/key behavior, Edge/Electron insertion, and actual login behavior have not all been verified. That VM presented only about 5–6 waveform frames per second; fluid animation there remains unresolved. Speeds vary with hardware, recording length, and optional AI formatting.

Mac and Windows use different AI formatting engines and are not claimed to have identical behavior. The Mac download is not notarized, and the Windows executable is not Authenticode signed.

## License and attribution

pFlow is based on [Yap by Frigade](https://github.com/FrigadeHQ/yap), under the [MIT License](LICENSE). The original copyright and license notice are retained. Pesh artwork and pFlow changes are distributed under the same license. whisper.cpp, its audio/model components, llama.cpp, Qwen, .NET, and Swift dependencies retain their own included licenses. Model downloads must keep their accompanying notices.

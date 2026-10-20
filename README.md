# pFlow by Pesh

Native dictation for macOS and Windows. Hold a key, speak, and release to insert text into the field you were using. Speech recognition runs locally through whisper.cpp. No account, subscription, telemetry, or API key is required.

## Downloads

[Download pFlow for Mac or Windows](https://github.com/PESHian/pFlow/releases)

These are testing builds. macOS and Windows may show an unsigned or unnotarized app warning. Only install downloads from this repository and check the supplied SHA-256 file.

| Platform | Download | Requirements |
| --- | --- | --- |
| Mac | pFlow-Mac-0.3.5-testing.dmg | Apple Silicon, macOS 27 or later |
| Windows | pFlow-Windows-Universal-0.1.15-testing.zip | Windows x64 (Intel/AMD), ARM64, or x86; Windows 10 1607+ / Windows 11 |

### Mac

Open the disk image and drag **pFlow by Pesh** into Applications. Open it and grant Microphone, Speech Recognition, Accessibility, and Automation permissions when asked. Hold **Right Command** to record, then release. Double-tap for continuous dictation; tap again to stop. Left Command stays available for shortcuts.

If double-tapping opens Siri, change Siri's Keyboard Shortcut in System Settings so it does not use Command twice.

The first use may need a checksum-verified Whisper model download. Apple Intelligence provides cleanup and report formatting when available. If it is unavailable, plain dictation remains available. This testing download is ad-hoc signed and not notarized. If macOS blocks it, use [Apple's Open Anyway steps](https://support.apple.com/en-us/102445) after checking the download.

### Windows

Extract the entire universal ZIP and double-click **Install.cmd**. It detects your native Windows architecture, checks the selected files, and installs the matching build for your user account. Open **pFlow by Pesh** from Start. It runs in the tray; open Settings from its tray menu. In **Settings → Shortcut**, choose **Press a key**, then press and release one key. Right Alt, either Ctrl, Menu/App, other F keys, and detectable vehicle buttons can be used. Common choices remain in the picker. Escape is reserved for cancellation. The chosen key records when used alone instead of its usual action; ordinary shortcut combinations remain available. Fn works only if the keyboard sends it as a usable keyboard event. Hold your chosen key to record, then release. Double-tap within about 300 ms for continuous dictation; tap to stop. Left Windows stays available unless you explicitly choose it. The choice is saved; existing installations keep Right Windows until changed.

The Windows download includes the Whisper speech model and .NET runtime. AI cleanup and report formatting use an optional 2.5 GB Qwen text model: choose **Download or repair text model** in Settings if you want those features. Its size and SHA-256 are checked before use. This optional text model requires 64-bit Windows; 32-bit Windows keeps dictation, basic cleanup, dictionary, and full-narrative templates. Basic dictation works without it. After setup, model inference runs offline.

No administrator password, separate .NET installation, or architecture choice is needed. Do not run an EXE copied out of its payload folder. See [full installation instructions](windows/INSTALLATION.txt). Windows 10 builds require version 1607 or later; Microsoft supports .NET 10 on its listed LTSC/Enterprise editions. Windows 7, 8, Windows RT/ARM32, and older releases are unsupported.

Quit pFlow before updating. Turn Mac dictation off before testing Windows recording in a VM on the same Mac.

## Updates

Choose **Check for updates** in the tray/menu bar or Settings, then **Install and restart**. pFlow checks a signed release list and verifies the download before replacing the app. Settings, history, and models stay on your device. Checks run only when requested. If your app has no Check for updates button, install a current build once using the steps above. Windows 0.1.11 and Mac 0.3.5 or later include the updater. Published GitHub binary releases become available in the app; source commits alone do not.

**One-time Mac step.** Mac 0.3.5 and the 0.3.6 test downloads run under the old internal name Yap, which is why macOS can show Yap in its permission lists. They cannot install the first build named pFlow themselves; they report that the update could not finish and keep your app. Install that build once by hand: quit pFlow, open the new disk image, drag **pFlow by Pesh** into the same Applications folder, and choose **Replace**. Settings, history, dictionary, templates, and models stay. macOS may ask for Accessibility and Automation again. If **System Settings → Privacy & Security → Accessibility** or **Automation** still lists Yap, select Yap, click **−**, then open pFlow and allow it again. Later updates work from the app.

Windows on/off controls show **On** or **Off** and a contrasting thumb. Settings shows the latest dictation time split into speech, AI cleanup, report formatting, and insertion when those stages ran. This readout contains no dictated words. AI cleanup remains optional; this release does not claim a processing speed improvement.

## Features

- Compact movable waveform, Wave and Lines styles, Pesh colors, light/dark/system themes.
- Dictionary, user templates, optional bold headings, local history, and daily/per-app statistics.
- Sentence spacing and paragraph boundaries; original text is retained when AI edits fail checks.
- Clipboard-copy can be off while insertion stays enabled. Clipboard restoration avoids replacing a newer copy.
- Password fields are excluded. Focus changes and unsupported fields can prevent insertion; the transcript remains in local history.
- Optional per-user launch at login.

### Live text: Type in the current app (Mac)

pFlow types words into the field you started in while you talk. It types only words two updates in a row agree on, so it runs a little behind. When you stop, it puts in the finished text (cleanup, dictionary, template) once. It writes with Accessibility text ranges, never keystrokes or the clipboard, and reads every write back.

Typing stops for the rest of the take if you move the cursor, type, switch apps or fields, the field becomes a password field, permission is removed, or a write does not read back exactly. The preview says why, and the finished text goes to History only. Cancel removes pFlow's words only if the field is still exactly as pFlow left it. Dictation does not start in password fields. Template styles such as bold arrive as plain text in this mode. The rules and their shared test cases are in `fixtures/live-text/inline-ownership`.

| Destination | Checked behavior |
|---|---|
| AppKit text view and text field in a test window (Unicode, CRLF, styled text, selection, cancel, edits) | Inline, through AppKit's own accessibility methods in the same process |
| Same, through real Accessibility calls | Not run: no test build on the test Mac has Accessibility permission |
| TextEdit (plain and rich), Safari text box and text area, VS Code | Not run, same reason. A Debug-only self-test (`--pflow-inline-selftest <folder>`) drives these with throwaway documents once a build is allowed |
| Field that cannot be read or set, has several cursors, or holds over 100,000 characters | Preview for the take (test field only) |

### Live text: Type in the current app (Windows)

Same rules as the Mac, shared through the same test cases. pFlow types only into classic Windows text boxes (Notepad, and edit and rich edit boxes in desktop apps), writing with the box's own text messages, never keystrokes or the clipboard, and reading every write back. Line breaks follow the box. Other fields, such as web pages in Edge and apps running as administrator, show the preview and get the finished text once when you stop.

| Destination | Checked behavior |
|---|---|
| Notepad, a Windows edit box and rich edit box in a test window (Unicode, CRLF, formatting, selection, cancel, edits, app and field switches, password field, a box that changes what was written) | Inline |
| Edge text box and text area on a local page | Preview |
| App running as administrator | Preview |
| Electron editor (VS Code) | Not run: not installed on the test PC |

## Privacy

Whisper transcribes audio on your device. Mac AI defaults to on-device processing. Source builds with Apple’s required entitlement can opt into Apple Private Cloud Compute, which sends text and formatting instructions to Apple; the supplied Mac testing download has no cloud entitlement. Windows AI runs locally. Model downloads contact their hosting services. History and settings stay in your user account, outside the app. Delete history entries when they are no longer needed.

This public repository contains application source, artwork, licenses, and fictional test fixtures. It does not include user settings, saved dictations, personal recordings, credentials, private development history, or device access files. The original private development repository has been retained separately.

## Build from source

Mac: install Xcode with the macOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate`, then build the Yap scheme from `Yap.xcodeproj`; it produces `pFlow.app`. `scripts/build-whisper.sh` prepares the pinned local engine. `release.sh` supports Developer ID signing/notarization when you supply your own credentials.

For trusted Mac candidates, follow the [signing setup and release checks](updates/MAC-RELEASE.md). Production packaging requires an approved Developer ID identity and notarization access. Development builds cannot use the production updater. Public download claims above remain tied to the published builds until a new candidate passes the clean-Mac checks.

Windows: install .NET 10 SDK, CMake, and Visual Studio C++ tools for your architecture, then run `windows/scripts/build-windows.ps1`. See [Windows details](windows/README.md). Use `-Architecture x64`, `-Architecture arm64`, or `-Architecture x86`. ARM64 native compilation uses the Clang C++ toolset; the other builds use MSVC with a static speech runtime. The published Windows binaries omit debug symbols. Release builds are checked for personal build paths; source builds need the same checks before distribution. Each architecture needs its own build and verification.

## Tested limits

Windows x64 and ARM64 builds have passed native Windows ABI, private clipboard restoration, and saved-audio transcription/reuse checks; x86 passed the same checks under Windows x64 WOW64. A native 32-bit Windows installation and old Windows 10/older CPU hardware remain unverified. Architecture support does not promise support for every historic Windows release or identical speed on all CPUs. The earlier Windows ARM64 build has been exercised on a Windows 11 VM, including saved-audio recognition, Notepad insertion, settings, templates, themes, and statistics. Physical microphone/key behavior, Edge/Electron insertion, and actual login behavior have not all been verified. That VM presented only about 5–6 waveform frames per second; fluid animation there remains unresolved. Speeds vary with hardware, recording length, and optional AI formatting.

Mac and Windows use different AI formatting engines and are not claimed to have identical behavior. The Mac download is not notarized, and the Windows executable is not Authenticode signed.

## License and attribution

pFlow is based on [Yap by Frigade](https://github.com/FrigadeHQ/yap), under the [MIT License](LICENSE). The original copyright and license notice are retained. Pesh artwork and pFlow changes are distributed under the same license. whisper.cpp, its audio/model components, llama.cpp, Qwen, .NET, and Swift dependencies retain their own included licenses. Model downloads must keep their accompanying notices.

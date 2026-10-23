# pFlow by Pesh for Windows

Native WPF application for x64 (Intel/AMD), ARM64, and x86 Windows. Download the universal ZIP, Extract All, double-click Install.cmd, and open pFlow by Pesh from Start. The installer chooses the native OS architecture even from an emulated or 32-bit shell. It requires Windows 10 1607+ or Windows 11; Microsoft supports .NET 10 on the listed Windows 10 LTSC/Enterprise editions. Older Windows/ARM32 is unsupported. The Mac source and notices remain intact above this directory.

Choose Right Ctrl, F8–F12, or Right Windows in Settings → Shortcut → Activation key. The choice is saved and takes effect immediately. Hold the chosen key to record; release to process and insert. Double-tap within 300 ms for continuous recording. Tap again to stop. Escape cancels. Shortcuts with the chosen key cancel recording and pass through. An already-held modifier keeps the shortcut available without starting dictation. Left Windows remains available for ordinary shortcuts.

The app runs in the tray. Right-click the capsule or tray to open Settings. The capsule shows only a waveform while recording and a moving line while processing, then hides. It keeps its placement, Wave/Lines, and dark/light/system themes. Use Show recording control in the tray menu to reveal it for a manual click. Settings and plain-text History stay in `%LOCALAPPDATA%\pFlow`. Recording files are removed after processing or cancellation. History contains sensitive dictation; delete entries when no longer needed.

Recognition uses local CPU whisper.cpp 1.9.5 and the Mac-pinned `ggml-small.bin`. The finished text keeps the greedy pass with the trimmed audio context (`windows/native/worker.cpp`): W025 measured the Mac's beam search and full context against it on fictional fixtures with no word-error gain at 1.4-3.5x the time, so speed wins. Whisper small is the one speech model (`PFlow.Core/SpeechModels.cs`); a damaged own copy left by an earlier version is passed over for the package's copy, and the live-words model stays `ggml-base-q5_1.bin`. The tray icon is the Pesh talking-pig mark, head and sound waves, cropped to fill its frame (`Assets/TrayOnDark.ico` / `TrayOnLight.ico`, 16-48 px, picked by the taskbar DPI and theme; at 16-24 px the waves are two clean arcs; `scripts/tray-icons.py` builds them from `Assets/Pesh.ico`, the original app icon). Settings pages scroll by pixel in proportion to the wheel delta (`SmoothScroll.cs`). Settings → Troubleshooting → Save a diagnostic report writes what the last takes did (live windows, typing writes, why typing stopped, the PC's processor, Windows build and models; never dictated words, titles, paths or the clipboard) to a text file in Downloads (in `%LOCALAPPDATA%\pFlow\Reports` when Downloads is in a cloud folder, through a junction or link too), shown in File Explorer. Model downloads validate both size and SHA-256. On launch, a private child process verifies and loads the speech model in the background. Its checked file stays locked against writes or replacement while loaded. Subsequent dictations reuse it; cancellation stops the owned worker and the next recording can restart it. Short clips use a smaller audio context that still covers every sample plus at least two seconds; longer clips keep the full context. The model and CPU baseline remain unchanged. No account, telemetry, browser interface, external API key, or cloud inference is used.

Report templates with their own sections need 64-bit Windows. On 32-bit Windows, that control and the text-model download are unavailable; dictation, cleanup, dictionary, and full-narrative templates remain usable. The section sorting uses a separate local text model: Qwen3-4B Q4_K_M (2.5 GB, Apache 2.0) through llama.cpp b11716 on the CPU. It selects complete source sentences for the saved sections and does not invent missing details; full narrative keeps the entire source. This differs from the Mac's free-form model-written summaries. Dictation cleanup is rule-based and English only: it removes filler words and adjacent repeated words and fixes capitals and spacing right away; other language presets keep their recognized words. The AI cleanup switch of 0.1.19-0.1.24 was removed in 0.1.25 (the owner found the model's punctuation poor and slow in real use); a saved settings file that still has it is read without it. Model failures leave dictation available. Windows AI APIs were not usable on the detected virtual ARM64 hardware, so Apple AI and Windows AI are not used.

Dictionary and template JSON use the Mac camel-case fields. Mac UserDefaults and SwiftData files are not portable Windows files; export JSON arrays before importing them into the Windows settings document. Windows does not read or migrate the Mac installation automatically.

Insertion checks the original app, focused field, selection, and text. Password fields are excluded whenever pFlow can see the field (a Chromium box still hidden behind its placeholder pane at insert time is typed into without a check, as 0.1.19 did). Unsupported accessibility providers, changed focus, changed text, or blocked elevated apps leave the transcript in History. An insertion is labeled successful only after observing the resulting text, normalizing Windows line endings. An uncertain insertion is never retried automatically. Plain dictation with clipboard-copy off uses ValuePattern or Unicode keyboard input and leaves the clipboard untouched. Rich text uses a materialized clipboard snapshot and restores it under the clipboard lock, comparing ownership before dispatch and restoration. Unsupported opaque clipboard representations fall back to plain Unicode insertion; bold formatting is then unavailable. No newer clipboard copy is overwritten by restoration. Physical focus can still change after the final Windows API check; a result that cannot be observed is retained in History.

## Build

Install .NET 10 SDK, CMake, and Visual Studio C++ build tools for the target architecture on Windows. Run `scripts/build-windows.ps1`. The script detects the OS architecture, builds a CPU-only engine from the checksum-pinned source, and publishes the matching self-contained WPF app. `scripts/install-windows.ps1` installs a published directory for the current user. Launch at login is an optional HKCU Run entry.

Core checks: `dotnet run --project windows/PFlow.Tests -c Release`.

Windows integration, physical microphone, hotkeys, keyboard mapping, clipboard, target apps, and login behavior must be recorded as tested or unverified in the build ledger. A Linux cross-build is not a Windows runtime test.

Unsupported fields keep recording usable and save the result to History. They receive no inserted text or clipboard change, even if focus moves later. Password fields pFlow can see still block recording. Click the waveform to record or stop without the hotkey; drag it to move the capsule. Speech language is a fixed preset, starting with English. Older automatic settings become English; choose another preset in Settings when needed.

Settings follows the Mac layout: the original Pesh artwork, Dark/Light/System segments, four gradient color cards, Wave/Lines previews and icon navigation rows. Custom Accent and Wave blend colors persist separately from the selected preset. The native Windows color chooser is used. The window keeps Windows title-bar controls.

The Windows app and Start shortcut use the speaking-pig icon. The recording capsule matches the Mac at 120 by 32 logical pixels, defaults to the focused display's bottom center, and saves a dragged position. Right-click it for Center at bottom. Its filled waveform uses elapsed-time interpolation between display frames. Smooth animation has not passed on the test VM: Windows compositor waits limit it to about 5 frames per second. Successive dictations add only needed spaces at the caret; selected replacements and paragraphs are preserved. Whisper segment line wraps are joined before conservative paragraph grouping.

Latency checks on the Windows ARM64 VM: fictional short and medium recognition took 0.68–0.72 seconds, a longer phrase 1.55 seconds, and an extended narration 4.73 seconds. Matching CLI baselines were 2.99–4.91 seconds and 6.80 seconds for the extended clip. The complete warm pipeline inserted a fictional sentence into Notepad in 0.76 seconds, excluding real microphone/key release; one earlier run exceeded six seconds before stage-level output was added, so this is not a universal deadline. Local last-processing-times.json stores only the last run’s numeric stage timings, without words, audio, paths or app names.

Templates start empty. Create and name your own templates, then edit and save their JSON sections. A one-time update removes only unchanged legacy examples; edited examples and custom templates stay. The original settings file is kept as settings-before-custom-templates.json before migration.

Public Windows downloads include Whisper and omit the optional Qwen weights to fit GitHub release assets. Download Qwen from Settings if needed. Release symbols and personal build paths are excluded. Usage statistics show four totals, seven calendar days, recent active days, and all-time apps; legacy words without timing do not inflate speaking pace.

Architecture checks run on Windows x64 and ARM64 hosts. x86 runs as an actual 32-bit process under WOW64 on Windows x64; no native 32-bit OS test is claimed. Each build checks native structure sizes, capsule window styles, private fictional clipboard restoration, and saved-public-audio transcription through the resident worker. Installer checks cover native selection from 32-bit shells, checksums, updates, user data, wrong architectures, and damaged packages. Physical microphone/key and old-PC performance coverage remains limited.

Choose Check for updates from the tray or Settings, then Install and restart. Updates use a signed release feed, checked downloads, your native Windows architecture, and the existing model files. Installation is blocked while dictation or clipboard restoration is active. First install this updater build with Install.cmd. See [release update publishing](../updates/README.md).

### Learn an activation key

In Settings > Shortcut choose **Press a key**, then press and release one key.
This supports standard Windows keyboard events, including Right Alt, either
Ctrl, Menu/App, app-launch buttons, F1–F24, and keys reported by a vehicle keypad.
The chosen key's standalone action becomes dictation. Shortcut combinations
remain available. Escape is reserved for cancellation. Key selection pauses
activation, rejects a multi-key chord, and keeps the old key if canceled or if
saving fails. It saves physical scan/extended identity for custom keys, rather
than recording a stream of typed keys.

Fn has no standard virtual-key code. This learner receives keyboard-hook events;
it does not subscribe to the separate, OEM-dependent system-button interface.
Some Fn buttons therefore cannot be learned. No manufacturer driver is installed.
See [Microsoft's Fn hardware guidance](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/system-button-narration).

Physical Fn, vehicle App buttons, and AltGr behavior on each international
keyboard need hardware testing. Synthetic/native sequence checks do not prove
that a particular keyboard or OEM driver sends the same events.

# Whisper live window fixtures

Shared by the Mac and Windows apps. Each file is one take: apply `windows` in
order to a fresh merger, then compare with `expected`. All text is fictional.
The merger only feeds the live preview. The finished text of a take always
comes from the normal whole-recording pass, so it includes the last words even
if a live window never heard them.

## Window

```json
{ "startMs": 2000, "endMs": 6000,
  "segments": [ { "fromMs": 0, "toMs": 1900, "text": " wound the brass clock.", "noSpeechProbability": 0.02 } ] }
```

- `startMs`, `endMs`: the audio the window covers, in milliseconds from the
  start of the take, counted from audio samples (16 samples per ms), never from
  the wall clock. That keeps long takes from drifting.
- `segments`: Whisper's segments for that audio. `fromMs`/`toMs` are relative to
  the window's `startMs`. `noSpeechProbability` is Whisper's no-speech
  probability for the segment.

## Expected

- `afterEach` (short files): the merged text after each window, one per window.
- `checkpoints` (long files): `{ "afterWindow": index, "text": ... }`, 0-based.
- `text`: the merged text after the last window.
- `committedEndMs`: where the kept words end after the last window.

## Rules

Constants: no-speech limit 0.6, settle 1000 ms, overlap 8 units.

1. Ignore a window unless `endMs` is later than the last applied window's
   `endMs`, later than `committedEndMs`, and later than its own `startMs`.
2. Drop segments that are not speech: no-speech probability of 0.6 or more,
   text (trimmed) wrapped in `[...]` or `(...)`, or text with no letter or digit
   (Unicode categories L and N), such as `♪`.
3. Each remaining segment becomes a piece with absolute times
   `from = startMs + max(0, fromMs)`, `to = min(endMs, startMs + max(fromMs, toMs))`,
   and trimmed text. Empty text is dropped.
4. If the window starts after `committedEndMs`, no later window hears the audio
   before `startMs`. For each piece left from the previous window, keep the words
   whose midpoint is before `startMs`: a unit spanning scalars `[a, b)` of a
   piece with `total` scalars is before when
   `2·from·total + (to − from)·(a + b) < 2·startMs·total` (whole numbers).
   Stop at the first unit that is not. Append the kept prefix of the text to the
   kept words. Then set `committedEndMs = startMs`. The previous window's pieces
   are then discarded either way.
5. Remove pieces with `to <= committedEndMs`.
6. Remove a repeat (Whisper's times are approximate, so a word at the boundary
   can be in both windows): take the last 8 non-empty unit keys of the kept
   words and the first 8 of the pieces. Find the largest `k` where the last `k` kept keys
   equal the first `k` piece keys. Cut the pieces right after that `k`-th unit,
   also dropping punctuation-only units at the cut. Remove pieces left empty.
7. Settle: while a piece is not the last one and its `to <= endMs − 1000`,
   append it to the kept words and set `committedEndMs = max(committedEndMs, to)`.
8. The rest are the window's words in progress. Shown text = kept words joined
   with each piece in progress.

## Units, keys, joining

- Text is handled as Unicode scalars (code points), not UTF-16 or graphemes.
- A unit is a run of non-whitespace scalars. Each scalar in U+3040–30FF,
  U+3400–4DBF, U+4E00–9FFF, U+F900–FAFF or U+20000–2FA1F (Chinese and
  Japanese) is a unit by itself.
- A key is the unit with punctuation (Unicode categories Pc Pd Ps Pe Pi Pf Po)
  removed, then lowercased. Keys compare exactly, so accents count.
- Joining two pieces: trim both; if either is empty use the other; if the last
  scalar of the left or the first of the right is in the ranges above, or the
  right starts with one of `,.!?;:)]}%…、。，！？：；」』）`, put nothing between
  them; otherwise one space.

## Live windows (not part of these fixtures)

The app plans windows from 16 kHz samples: every 1000 ms of new audio, a window
from `max(committedEndMs, now − 15 s)` to now, at least 1 s long. A window
whose new audio has no speech (fewer than five 30 ms frames above RMS 0.01) is
skipped with no inference. One window runs at a time; while it runs, new audio
waits, and the next window takes the newest audio, so nothing queues.

`long-session.json` was generated from a fictional narration with that planner;
its expected text is what the narration said, not the output of any merger.

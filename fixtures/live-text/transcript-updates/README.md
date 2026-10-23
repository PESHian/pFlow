# Transcript update fixtures

Shared by the Mac and Windows apps. Each file is one scenario for the live text
reconciler: feed `events` in order, then compare with `expected`. All text is
fictional.

## Update

```json
{ "session": "take-a", "sequence": 3, "text": "The whole transcript so far", "isFinal": false }
```

- `session`: the take this update belongs to.
- `sequence`: increases within a take, in the order the engine produced it.
- `text`: the complete current transcript, not an appended piece. A recognizer
  may rewrite earlier words, so each update replaces the previous text.
- `isFinal`: the last update of the take. Nothing after it counts.

## Events

- `{"op": "begin", "session": "take-a"}` starts a take and clears all state.
- `{"op": "update", ...the update fields}` delivers one update.
- `{"op": "cancel"}` cancels the current take and clears its text.

## Rules

An update is ignored when no take is open, when it belongs to another take,
when its `sequence` is not higher than the last applied one, or when it comes
after the final update or a cancel. An applied update whose text equals the
current text changes nothing on screen.

## Expected

- `shown`: each text the preview displays, in order (only applied updates that
  changed the text).
- `text`: the text held after the last event.
- `phase`: `idle`, `open`, `final` or `cancelled`.

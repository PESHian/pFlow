# Inline ownership fixtures

Shared by the Mac and Windows apps. Each file is one take of "Type in the
current app": the destination field as captured before any pFlow window
appeared, then transcript updates, the person's own actions, and the final or
cancel. All text is fictional.

Every position and length is in **UTF-16 code units**, the unit macOS
Accessibility and .NET strings use. Text is compared code unit by code unit,
never by canonical equivalence ("é" as one code point is not "e" + U+0301).

## Field

```json
{ "app": 1, "element": "target", "secure": false, "trusted": true,
  "value": "Note: ", "selection": [6, 0] }
```

- `app`: the frontmost app's process. `element`: `"target"` while the captured
  field has focus, anything else otherwise.
- `secure`: a password field, or secure input is on. `trusted`: pFlow has
  Accessibility (Mac) or UI Automation access (Windows).
- `value`: the field's whole text, or `null` when it cannot be read.
- `selection`: `[location, length]`.

`begin.writable` is the native check, made without writing anything: the
selected range and selected text can be set. A field reports no `selection`
when it has more than one (several cursors), and no `value` when it is longer
than 100,000 UTF-16 units, so pFlow does not read a huge document on every
update. Either means Preview at begin and a stop during a take.
`beginResult` is `ready`, or the stop reason that makes the take use Preview.

## Steps

The runner keeps a simulated field, starting from `begin.field`.

- `update {text}`: the whole transcript so far (after the transcript-updates
  reconciler). Ask the session what to write.
- `final {text}`: the finished, cleaned text. Ask what to write.
- `cancel`: ask what to write to take pFlow's words back out.
- `edit {range, text, caret?}`: the person replaces `range` with `text`. The
  selection becomes `caret`, or a caret after the new text.
- `select {range}`: the person moves the caret or selects.
- `app {pid}`, `focus {element}`, `secure {secure}`, `trust {trusted}`: the
  person switches apps or fields, the field turns secure, or permission changes.

`expect` is one of:

- `{"action": "none"}`: write nothing.
- `{"action": "write", "range", "text", "select"?, "confirm"}`: replace `range`
  with `text`, then set the selection to `select` if given (cancel only),
  otherwise the caret ends after `text`. The runner applies it to the simulated
  field, unless the step has `apply`: `{"value"?, "selection"?, "accepted"?}`,
  which is what the app did instead (`accepted: false` means the write call
  failed). Then it reports the field back; `confirm` is `ok` or `uncertain`.
- `{"action": "stop", "reason"}`: write nothing, and live typing is stopped (or,
  for final and cancel, refused) for this reason.

An optional `field {value, selection}` on a step is the simulated field after it.

## Rules

1. Begin is refused without permission (`permission`), in a secure field
   (`secure`), or when the field cannot be read, is over 100,000 units, has no
   single selection, or its range cannot be written (`unsupported`). The take then uses Preview.
2. pFlow owns one span, starting at the original selection. Before every write
   it checks, in order: `permission`, `app`, `focus`, `secure`, then that the
   whole value is exactly the text before the span + the owned text + the text
   after it (`text`), then that the selection is exactly where pFlow left it
   (`caret`; before the first write, the original selection). The first failure
   stops typing for the take. Nothing is written for that take afterwards,
   even if things return to how they were.
3. Only settled words are typed: the words two consecutive updates agree on,
   cut back to where a word has ended in both (whitespace, punctuation other
   than an apostrophe or hyphen, or a Chinese/Japanese character; the end of
   the older update counts, the end of the newer one does not unless both are
   identical). The first update settles nothing.
4. While the newest transcript still starts with the words already typed
   (ending at a word end), and the settled words are not longer, nothing is
   written. Otherwise the owned text becomes the settled words with the same
   spacing rule as final insertion (`InsertionSpacing`), and pFlow replaces
   from the first differing character to the end of its span, so the caret
   ends after its text.
5. Every write is read back. Anything other than exactly the expected value
   and caret, or a failed call, is `uncertain`: typing stops and the write is
   not retried.
6. The final replaces the owned span once with the finished text (same
   spacing rule), after the same checks. After a stop it is refused, and the
   app keeps the finished text in History.
7. Cancel writes nothing if pFlow typed nothing. After an uncertain write it is
   refused. Otherwise, only if the checks in rule 2 pass right now, it puts the
   original selected text back and selects it again. A later edit by the
   person, anywhere in the field, means cancel leaves everything alone.

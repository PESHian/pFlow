# Speed fixtures

Fictional reference texts for the timing runs (Mac `Tests/SpeedHarnessTests.swift`,
Windows `PFlow.LiveTests --speed`). Five short (about 7 s spoken), five medium (about 20 s)
and one long narration (about 3 minutes). No real people, places or private text.

Audio is generated on each host from these texts with the system voice, so the same
recording is used for every before/after run on that host:

- Mac: `say -v Samantha --file-format=AIFF --data-format=BEI16@16000 -o <name>.aiff -f <name>.txt`
- Windows: System.Speech `SpeechSynthesizer` default voice, 16 kHz mono 16-bit WAV.

The recordings are not committed. The ledger records each file's SHA-256 next to the
numbers it produced.

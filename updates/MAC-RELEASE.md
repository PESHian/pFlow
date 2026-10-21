# Trusted Mac releases

The release candidate is 0.3.9, for Apple Silicon and macOS 27 or later. Existing
public 0.3.5 downloads remain development signed. Do not describe a candidate as
ready for users until the checks below pass on its exact downloaded bytes.

## Signing access

**Public signing is on hold.** Do not sign a production candidate, submit it to
Apple or upload it until the owner lifts the hold. Pesh is the public identity;
the owner's personal name and email must stay out of public work, including
certificates, commit metadata, build logs and release assets. Use Pesh and a
GitHub noreply address for commit credit. Keep Apple account email addresses in
Keychain or protected secrets only.

Use a paid Apple Developer Program team and a usable Developer ID Application
certificate with its private key. Before signing, the owner must approve the
certificate's exact Pesh organization name. Inspect its full public contents
privately for personal names and email addresses; checking its display name
alone is insufficient. Do not use a personal-name certificate or relabel one as
Pesh. Apple's certificate carries the team name and Team ID; the app's name
does not change that identity.

On the Mac, use Xcode Settings > Accounts > the team > Manage Certificates > + >
Developer ID Application. Store notarization credentials interactively:

```sh
xcrun notarytool store-credentials yap-notary \
  --apple-id "YOUR_APPLE_EMAIL" --team-id "YOUR_TEAM_ID"
```

Replace the email and Team ID placeholders, then enter an app-specific password
at the secure password prompt. With the bare command, leave the first API key
file prompt empty to select Apple ID authentication. Do not
put a password in shell history, git, chat or build logs. Keep a protected backup
of the signing identity. Do not revoke an existing certificate for this task.

Production packaging requires these nonsecret selections in the environment:

- `PFLOW_DEVELOPER_TEAM`: the approved ten-character Apple team ID.
- `PFLOW_SIGNING_IDENTITY`: the exact usable certificate's 40-character SHA-1.
- `PFLOW_APPROVED_PUBLISHER`: the approved publisher portion of its common name.
- `YAP_NOTARY_PROFILE`: the Keychain profile; defaults to `yap-notary`.
- `PFLOW_SIGNING_KEYCHAIN`: optional explicit Keychain path.

Leave `PFLOW_APPROVED_PUBLISHER` unset while signing is held. A matching
certificate alone is not permission to release it.

From a clean committed checkout of reviewed main, run `bash release.sh`. It builds
with the approved update team embedded in the sealed Info.plist. `--app PATH`
accepts an already built app with that same team. Neither path chooses the first
certificate or falls back to development signing. `--testing [PATH]` remains
available for development; it cannot create a trusted-release receipt.

The packager signs executable code inside out with timestamps and Hardened
Runtime, checks signatures and entitlements, obtains Accepted notarization for
an app ZIP, and staples and validates the app. It then builds, signs, notarizes,
staples and assesses the DMG, and verifies the app mounted from that exact DMG.
Hashes and the receipt are written after these checks. Only the app and retained
license notices enter the image or notarization archive; user data is never an
input to the release job.

## Protected automation

Create a GitHub environment named `mac-trusted-release`, restrict it to main,
require owner approval, and prevent self-approval. Review changes to release
scripts and workflows before allowing this environment's secrets to be used.
Configure its variables from the approved identity above. Also set the repository
variable `PFLOW_DEVELOPER_TEAM` to that same team for feed verification.

Store these values as environment secrets through GitHub's protected settings:

- `PFLOW_CERTIFICATE_P12`: base64 of the exported identity, including private key.
- `PFLOW_CERTIFICATE_PASSWORD`: the export password.
- `PFLOW_NOTARY_APPLE_ID` and `PFLOW_NOTARY_PASSWORD`: Apple ID and app-specific password.

Provision fresh macOS 27/Xcode 27 ARM64 VMs with XcodeGen and CMake already
installed. The `pflow-mac-release-ephemeral` runner pool is for reviewed main only.
Destroy the VM after each job, including cancellation or failure. Its private
keychain is created only after builds/tests complete and is removed afterward.
The separate `pflow-mac-test-ephemeral` pool has no signing identities or secrets.
Neither pool may reuse a personal Mac session or accept work from the other pool.
Runner labels alone do not provide that isolation; configure the pools before
enabling the workflows.

Dispatch **Trusted Mac candidate** on current main. The signing job uploads the
DMG, checksum and `.trusted.json` receipt to GitHub with 90-day retention. A
GitHub-hosted job attests the DMG and receipt. Download and keep the exact candidate
outside the VM before testing. No workflow here publishes a candidate automatically.

The public feed requires the receipt as a release asset. It checks its bytes,
team, notarization results and matching DMG hash, then verifies GitHub provenance
from this repository's `mac-trusted-release.yml` on main at the receipt's source
commit. A JSON file without valid provenance cannot authorize a Mac update.
Windows-only releases need no Mac signing access. The publisher retains all
existing platform entries and uses a non-forced atomic update of current main;
if Windows work advances main concurrently, retry against its new head.

## Checks before publication

- Rebase the Mac branch onto current public main before review/publication. Keep
  the parallel Windows changes, feed entries, licenses and existing release assets.
- Record the candidate filename, SHA-256, source commit and both Apple submission
  IDs outside the VM. Confirm the receipt matches the final downloaded DMG.
- In a clean supported Mac state, download through a browser with Gatekeeper on.
  Keep its real quarantine. Mount, drag to Applications and open normally. Do not
  use Open Anyway, strip quarantine or change security policy to obtain a pass.
- In a separate clean state, download first, disconnect networking before any
  mount, launch or trust assessment, and test first launch offline. An online
  launch or assessment in the same state would contaminate this check. Speech
  model downloads are separate from trusting the app.
- Test the public 0.3.5 updater and a trusted installed build against this exact
  candidate. Verify the relaunched version and original application path. Check
  cancellation, failed launch and rollback with fictional data. Retain private
  settings, dictionary, templates, history and model files. Until the actual
  0.3.5 transition passes, use a one-time installation from the signed DMG and do
  not promise automatic migration. The helper/process fixtures are not that test.
- Test signature corruption, an ad-hoc candidate and an independently valid
  wrong-team Developer ID app. The team-policy test first accepts that fixture
  under its own team, then rejects another team, without any pFlow bundle checks.
  Set `PFLOW_TRUST_FIXTURE_APP` and `PFLOW_TRUST_FIXTURE_TEAM` for that native test;
  without them it is explicitly skipped. These values never relax app policy.
- With Windows dictation off, check Mac permission prompts, microphone, key hold
  and release, continuous mode, offline speech, capsule, insertion, clipboard
  restoration, saved settings, login registration and relaunch. A new signing
  identity may require permission approval again. Do not reset user data.
- Obtain a fresh correctness/security/test review. Publish a new versioned release
  only after the owner tests it. Upload the unchanged DMG, checksum and attested
  receipt. Retain prior downloads. Then verify the actual signed feed and downloads.

Keep the name `pFlow-Mac-VERSION-testing.dmg` for this first trusted release.
Public 0.3.5 updaters require it. The suffix describes compatibility, not the
signature; receipts, Apple tickets and the clean installation checks prove trust.
Update the public download instructions only after those checks pass.

[Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

[Apple code signing](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

[Apple certificate identities](https://developer.apple.com/help/account/certificates/certificates-overview/)

[GitHub Actions security](https://docs.github.com/en/actions/reference/security/secure-use)

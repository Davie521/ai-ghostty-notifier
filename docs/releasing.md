# Releasing

A release is a GitHub Release carrying three assets, built and published by
[.github/workflows/release.yml](../.github/workflows/release.yml) when a tag
`vX.Y.Z` is pushed:

| Asset | What it is |
| --- | --- |
| `ai-ghostty-notifier-macos.zip` | `ClaudeGhosttyNotify.app` (universal, Developer ID signed, notarized, stapled), the hook launchers, and the scripts that install them |
| `setup.sh` | the one-command installer, which downloads the zip above |
| `SHA256SUMS` | checksums of both |

Users install the way the README says, by pasting a prompt into their coding
agent; that does not change when releases exist.
[docs/agent-install.md](agent-install.md) checks for a release first, and when
there is one the agent runs

```bash
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
```

instead of building from source. It checks the checksum, that the App is a
notarized Developer ID build, then installs the App and registers the hooks;
nothing is compiled ([scripts/setup.sh](../scripts/setup.sh)). The same line
works without an agent. The asset names carry no version so that
`releases/latest/download/…` always resolves.

## One-time setup

Everything here needs a person with the Apple Developer account; nothing in it
can be done from CI.

### 1. A Developer ID Application certificate

Only the Account Holder of an Apple Developer Program membership can create it.

1. On a Mac: Keychain Access → Certificate Assistant → Request a Certificate
   From a Certificate Authority → saved to disk. This leaves the private key in
   the login keychain.
2. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list)
   → **+** → **Developer ID Application** (G2 Sub-CA) → upload the request →
   download the `.cer` and double-click it. Keychain Access now shows
   *Developer ID Application: NAME (TEAMID)* with its key under it.
3. Export that identity (certificate **and** key) as a `.p12` with a strong
   password. Keep both in 1Password; the `.p12` on disk can go afterwards.

The name in the certificate is what macOS shows as the developer of the App.

### 2. A notarization API key

[App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)
→ Users and Access → Integrations → **Team Keys** → **+**, access *Developer*.
Download `AuthKey_<KEYID>.p8` (Apple allows exactly one download) and note the
**Key ID** and the **Issuer ID** shown above the list. Keep all three in
1Password.

### 3. Repository secrets

`gh secret set` reads the value from standard input. Strip newlines from the
base64 so the stored value is exactly the encoding, and type the password at
the prompt rather than on the command line, where it would land in shell
history and `ps`:

```bash
R=Davie521/ai-ghostty-notifier
base64 -i DeveloperID.p12 | tr -d '\n' | gh secret set DEVELOPER_ID_CERT_P12_BASE64 -R $R
gh secret set DEVELOPER_ID_CERT_PASSWORD -R $R          # prompts
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | gh secret set NOTARY_KEY_P8_BASE64 -R $R
gh secret set NOTARY_KEY_ID -R $R                       # prompts; the 10-character Key ID
gh secret set NOTARY_ISSUER_ID -R $R                    # prompts; the Issuer ID (a UUID)
gh secret list -R $R
```

A run that should sign fails at *Check the signing secrets*, naming what is
missing, and never builds or publishes an ad-hoc App instead.

### 4. Rehearse a signed run without publishing

Actions → **Release** → **Run workflow**, with *Sign with the Developer ID and
notarize* ticked. It signs, notarizes, packages, installs the package into a
private home, and uploads the assets as an artifact; it publishes nothing. (The
artifact is visible to anyone who can see the repository, for seven days.) The
log of *Notarize and staple* ends in `source=Notarized Developer ID` when the
secrets are right.

Then install that artifact on a Mac and click a real notification: it must land
on the session's tab, not just bring Ghostty forward. This is the one check of
the Apple Events entitlement that nothing automated makes. The live binding
test (`tests/test-live-binding.sh`) runs its hooks from inside a Ghostty tab,
and macOS attributes their Apple Events to Ghostty itself, so it passes with or
without the entitlement (checked: a hardened build re-signed without it still
bound 3 of 3). The click comes from the resident, which launchd starts on its
own account, and that is where the hardened runtime refuses Apple Events
without the entitlement.

Run without the box ticked, the same pipeline uses an ad-hoc signature and no
secrets at all: a quick check that the build, the packaging and `setup.sh`
still work together.

## Cutting a release

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
   [agent/Resources/Info.plist](../agent/Resources/Info.plist), and `version` in
   [.claude-plugin/plugin.json](../.claude-plugin/plugin.json). Merge to `main`.
   The workflow refuses a tag that does not match `Info.plist`.
2. Tag the merge and push the tag:

   ```bash
   git switch main && git pull --ff-only
   git tag v0.5.0 && git push origin v0.5.0
   ```

3. Watch the run. When it is green, the release exists, and from then on the
   README's prompt installs it without building anything; the prompt needs no
   change. Check it once on a Mac, ideally one that never had a local build:

   ```bash
   curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
   ```

A failed run publishes nothing; fix, then delete and re-push the tag.

## What the release build changes

`scripts/build-agent.sh` takes the release's options; a local build takes none
and is signed ad-hoc as before:

- `--universal`: arm64 and x86_64 in one binary.
- `--sign IDENTITY`: Developer ID signature with the **hardened runtime**, which
  notarization requires. Under it the App may send Apple Events only because of
  the `com.apple.security.automation.apple-events` entitlement in
  [ClaudeGhosttyNotify.entitlements](../agent/Resources/ClaudeGhosttyNotify.entitlements);
  without it, clicking a notification would activate Ghostty but never reach
  the tab. `--hardened` gives the same with an ad-hoc signature, which is what
  CI builds, so every suite runs under the hardened runtime.
- `--no-system-sounds`: Apple's `/System/Library/Sounds` are not bundled, since
  a published archive must not redistribute them. The 10-minute tier then plays
  the default notification sound rather than Glass. A local build still bundles
  them.

macOS keeps notification and Automation permission against the code signature.
A Developer ID signature stays the same from one release to the next, so
upgrading does not ask again; moving from a local ad-hoc build to a release
asks once.

## Who can sign

The certificate and the notarization key sit in this repository's Actions
secrets. Anyone who can push a `v*` tag, or change a workflow on `main`, can
produce an App signed with that identity. Restrict tag creation (a tag ruleset
for `v*`) and keep workflow changes behind reviewed pull requests. If a token
that can write workflows may have leaked, revoke the certificate in the Apple
Developer account and the API key in App Store Connect, not just the token.

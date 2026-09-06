# Releasing Overture

Overture ships as a signed, notarized DMG (no App Store — the app spawns the
user's own CLIs and cannot be sandboxed) plus a Homebrew cask, with Sparkle
for updates.

## One-time setup

1. **Developer ID Application certificate** (this is NOT the App Store
   "Apple Distribution" cert): Xcode → Settings → Accounts → your team →
   Manage Certificates → **+** → *Developer ID Application*. Requires the
   Account Holder role. Verify with:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

2. **Notarization credentials** (app-specific password from
   appleid.apple.com → Sign-In & Security):

   ```bash
   xcrun notarytool store-credentials overture-notary \
     --apple-id <your-apple-id> --team-id B2DYXY7U9Y \
     --password <app-specific-password>
   ```

3. **Sparkle update-signing keys** (once, at first release):

   ```bash
   # generate_keys ships inside the resolved Sparkle artifact:
   .build-app/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   - The **public** key goes into `App/Info.plist` → `SUPublicEDKey`
     (replace the placeholder), and set `SUEnableAutomaticChecks` to true.
   - The **private** key goes ONLY into the `SPARKLE_ED_PRIVATE_KEY` GitHub
     secret (and a password manager). Never commit it; rotate by generating
     new keys and shipping one release signed with both.
   - Update `SUFeedURL` to the real appcast location once the repo is public.

4. **CI secrets** for `.github/workflows/release.yml`:
   `MACOS_CERT_P12` (base64 of the exported Developer ID .p12),
   `MACOS_CERT_PASSWORD`, `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`,
   `NOTARY_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY` — see
   [Setting the CI secrets](#setting-the-ci-secrets) below.

## Setting the CI secrets

Notarization authenticates with an **App Store Connect API key**, not an Apple
ID and app-specific password. The key is not invalidated when the Apple ID
password changes, needs no 2FA, and can be revoked on its own — an
app-specific password fails all three, and silently: changing your Apple ID
password revokes every one of them, and Apple then answers `HTTP 401 Invalid
credentials` with no indication why.

**1. Create the key.** App Store Connect → Users and Access → Integrations →
App Store Connect API → **Team Keys** → generate one with the *Developer*
role. Download the `.p8` — it can only be downloaded **once** — and note the
Key ID (also in the filename, `AuthKey_<KEYID>.p8`) and the Issuer ID (the
UUID at the top of that page).

Keep the key out of the repo and readable only by you:

```bash
mkdir -p ~/.appstoreconnect/private_keys && chmod 700 ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
```

**2. Prove it works before storing it anywhere.**

```bash
xcrun notarytool history \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <ISSUER_ID>
```

Submission history means all three values are right. Fix any error here, not
in GitHub.

**3. Store it locally** so `scripts/notarize.sh` works without env vars:

```bash
xcrun notarytool store-credentials overture-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <ISSUER_ID>
```

**4. Store it in GitHub.** `gh secret set` stores stdin verbatim and `echo`
appends a newline, which corrupts single-token secrets — use `printf`:

```bash
base64 -i ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  | gh secret set NOTARY_KEY_P8_BASE64 --repo omerburakpolat/overture
printf '%s' "<KEYID>"     | gh secret set NOTARY_KEY_ID    --repo omerburakpolat/overture
printf '%s' "<ISSUER_ID>" | gh secret set NOTARY_ISSUER_ID --repo omerburakpolat/overture
```

The base64 blob is the one secret allowed to contain newlines — it wraps by
design, and the workflow decodes it and checks the result is a PEM private
key before using it.

The release workflow validates all three secrets against Apple before it
builds, so a bad one fails in seconds rather than after a signed build.

## Cutting a release

```bash
git tag v0.1.0 && git push origin v0.1.0
```

CI builds, signs, notarizes, staples, generates the appcast, and attaches
everything to the GitHub release. Then update the cask
(`packaging/overture.rb`) in the tap with the new version + sha256.

## Local dry run (no Developer ID needed)

```bash
scripts/release.sh 0.0.0-dev "Apple Development"
```

Builds and signs with the development certificate and produces a DMG.
Gatekeeper will (correctly) refuse it on other machines — it verifies the
pipeline, not distributability. A full local distribution run:

```bash
scripts/release.sh 0.1.0            # needs Developer ID Application
scripts/notarize.sh build/Overture-0.1.0.dmg
```

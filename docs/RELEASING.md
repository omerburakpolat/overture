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
   `MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`,
   `NOTARY_TEAM_ID`, `SPARKLE_ED_PRIVATE_KEY`.

## Setting the CI secrets

`gh secret set` stores stdin verbatim, and `echo` appends a newline — a
newline inside `NOTARY_PASSWORD` produces `HTTP 401 Invalid credentials` from
Apple with no hint as to why. Use `printf`, and test the credentials before
storing them:

```bash
# 1. Prove the values work, before they go anywhere near GitHub.
read -rs "?App-specific password: " PW && echo
xcrun notarytool history --apple-id "<your-apple-id>" \
  --team-id B2DYXY7U9Y --password "$PW"

# 2. Only if that printed submission history, store it — no newline.
printf '%s' "$PW" | gh secret set NOTARY_PASSWORD --repo omerburakpolat/overture
printf '%s' "<your-apple-id>" | gh secret set NOTARY_APPLE_ID --repo omerburakpolat/overture
printf '%s' "B2DYXY7U9Y"      | gh secret set NOTARY_TEAM_ID  --repo omerburakpolat/overture
unset PW
```

`NOTARY_PASSWORD` must be an **app-specific password** from
appleid.apple.com → Sign-In & Security → App-Specific Passwords — not your
Apple ID password, and not a password from a different Apple ID than the one
in `NOTARY_APPLE_ID`. Changing your Apple ID password revokes every
app-specific password, so a release that used to work can start failing with
401 for that reason alone.

The release workflow validates all three secrets before it builds, so a bad
one now fails in seconds rather than after a signed build.

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

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

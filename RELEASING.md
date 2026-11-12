# Releasing Lapang

One command builds, signs, notarizes and publishes a version. Installs pick it up through Sparkle's daily check, and Homebrew users through the tap.

```bash
./release.sh 0.2.0 --dry-run   # everything short of publishing
./release.sh 0.2.0             # asks once, then publishes
```

## Where things live

| What | Where |
|---|---|
| Version | `Support/Info.plist`: `CFBundleShortVersionString` (semver) and `CFBundleVersion` (build number, +1 per release). `lapang --version` prints both. |
| Download | GitHub Release `vX.Y.Z` on `afiqsazlan/lapang`, asset `Lapang-X.Y.Z.zip` (notarized, stapled, universal) |
| Update feed | `public/lapang/appcast.xml` in the private repo `afiqsazlan/afiqsazlan.com`, served at https://www.afiqsazlan.com/lapang/appcast.xml (Cloudflare Pages, live about a minute after a push to `main`) |
| Homebrew | `Casks/lapang.rb` in the public repo `afiqsazlan/homebrew-tap`: `brew install --cask afiqsazlan/tap/lapang` |
| Update signing key | Sparkle EdDSA key in your login keychain, account `lapang`. The public half is `SUPublicEDKey` in `Support/Info.plist`. |

Only builds made by `release.sh` (`LAPANG_RELEASE=1`) carry the feed URL. A plain `./build.sh` leaves it out, so a build from source never replaces itself with a release.

## One-time setup (needs your Apple login, so only you can do it)

1. **Developer ID certificate.** In Xcode → Settings → Accounts, select your team → Manage Certificates… → + → **Developer ID Application**. Only the team's Account Holder can create one. Check it, then export the identity for `release.sh`:

   ```bash
   security find-identity -v -p codesigning
   ```

   ```bash
   echo 'export LAPANG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"' >> ~/.zshrc
   ```

   Back the certificate up as well: Keychain Access → My Certificates → right-click it → Export… as a `.p12`, with the password in your password manager.

2. **Notarization credentials.** Create an app-specific password at https://appleid.apple.com (Sign-In and Security → App-Specific Passwords), then store it in the keychain. `notarytool` prompts for the password itself:

   ```bash
   xcrun notarytool store-credentials lapang-notary --apple-id you@example.com --team-id TEAMID
   ```

   ```bash
   xcrun notarytool history --keychain-profile lapang-notary
   ```

   An empty history means it works.

3. **Back up the Sparkle key. Do this now.** Every installed copy only accepts updates signed with this key. Lose it and existing users can never update again: they'd have to download a new build by hand. Export it to a file, put the file in your password manager (or another encrypted backup) and delete the local copy:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account lapang -x ~/Desktop/lapang-sparkle-private-key
   ```

   To restore it on a new Mac: `generate_keys --account lapang -f <file>`. The tools appear in `.build/artifacts/sparkle/Sparkle/bin` after `swift package resolve`.

4. `gh auth status` must show an account with push access to `afiqsazlan/lapang`, `afiqsazlan/afiqsazlan.com` and `afiqsazlan/homebrew-tap`.

## Cutting a release

1. On `main`, with a clean tree in sync with `origin/main`, run the dry run:

   ```bash
   ./release.sh 0.2.0 --dry-run
   ```

   It checks the identity, notary profile, Sparkle key and `gh`, then builds, signs, notarizes, staples, zips and EdDSA-signs. It writes the new appcast item and cask into a temp folder (the path is printed) and stops before committing anything. Your `Info.plist` is left as it was.

2. Release notes default to the commit subjects since the last tag. To write your own, pass a Markdown file. The notes go to the GitHub Release and, as HTML, into Sparkle's update window:

   ```bash
   ./release.sh 0.2.0 --notes notes.md
   ```

3. Run it for real. It asks once before the first push:

   ```bash
   ./release.sh 0.2.0
   ```

   The steps, each stopping the release if it fails:
   1. bump `Info.plist`
   2. build universal with Sparkle embedded
   3. sign with Developer ID and the hardened runtime
   4. notarize with `notarytool --wait` and staple, then check with `spctl`
   5. zip
   6. `sign_update`
   7. commit `Release X.Y.Z`, tag `vX.Y.Z`, push
   8. `gh release create`, then re-download the asset to confirm its sha256
   9. push the appcast item to the site
   10. push the cask to the tap

   If a step after 7 fails, the error prints the command or the temp clone to finish from.

4. Check the feed shows the new version:

   ```bash
   curl -s https://www.afiqsazlan.com/lapang/appcast.xml | grep shortVersionString
   ```

   A running copy finds it within a day, or straight away with **Check for Updates…** in the gear menu.

Formats: a zip, because Sparkle and Homebrew both handle it and the `.app` inside stays stapled. The cask has `auto_updates true`, so `brew upgrade` leaves Lapang to Sparkle unless you run `brew upgrade --greedy`.

## Active installs by version

Lapang sends no telemetry. The daily update check is its only network request, and the site's request logs are the install count.

- Every running copy with automatic checks on fetches `/lapang/appcast.xml` about once every 24 hours, and Sparkle's User-Agent carries the version: `Lapang/0.1.0 Sparkle/2.10.1`. The format string `%@/%@ Sparkle/%@` (app name, `CFBundleShortVersionString`, Sparkle version) is in the bundled `Sparkle.framework`.
- System profiling (`SUEnableSystemProfiling`) is off, so the request carries no query string about the Mac.
- In Cloudflare: afiqsazlan.com zone → Analytics & Logs → HTTP Traffic, filtered to path `/lapang/appcast.xml`, gives requests per day, which is roughly daily active installs. Requests by User-Agent, which is versions, need the GraphQL Analytics API (`httpRequestsAdaptiveGroups`, with `clientRequestPath` and `userAgent` as dimensions) or Logpush, depending on your Cloudflare plan. The dashboard's top user agents list shows it too, where the plan has it.
- Counts are approximate. Copies with automatic checks turned off never appear, and one Mac checking twice in a day counts twice.

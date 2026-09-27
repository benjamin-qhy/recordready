# RecordReady macOS release tooling

Requirements: Apple Silicon macOS, Bun, npm, Xcode command-line tools, the project's installed desktop dependencies. Sparkle 2.10.0 is downloaded from the official release and checked against a pinned SHA-256 before extraction. Adapted from HaiqiAI's release pipeline; no Electron components are used.

## Validate without packaging or deployment

```sh
bun test scripts/release
python3 scripts/release/deploy-remote.test.py
bun scripts/release/prepare-sparkle.ts
```

`prepare-sparkle.ts` only populates `desktop/vendor/sparkle` and a user cache. It never builds the app, creates signing keys or deploys. Native builds must link Sparkle from this directory and use `@executable_path/../Frameworks` for runtime loading.

## Package two validation releases

```sh
bun scripts/release/build-release.ts 0.1.0-beta.1 10001 site/notes-beta.1.json
bun scripts/release/build-site.ts
# Install beta.1 manually before publishing beta.2 for an actual update test.
bun scripts/release/build-release.ts 0.1.0-beta.2 10002 site/notes-beta.2.json
bun scripts/release/build-site.ts
```

Each build passes its version through Tauri's configuration override, checks an arm64-only main executable, embeds Sparkle, writes bundle and update metadata, signs nested Mach-O files and bundles inside-out, verifies the final app, creates/restores/verifies its full ZIP, and creates/verifies a DMG with an Applications shortcut. Appcast full updates use ZIP. Ed25519 signatures on ZIP and deltas are verified using Sparkle's own tool. Delta candidates come from the latest three catalog entries and each base ZIP must match its recorded SHA-256; every patch is applied and its resulting code signature checked. Deltas that are not smaller than the full ZIP are omitted, leaving the full ZIP fallback available.

Update scheduling belongs to the native custom driver. Bundle keys disable Sparkle's automatic download/install and automatic checks, require verification before extraction, and disable the installer launcher service for this unsandboxed app. The public key/feed URL are set before final signing.

Keys are created only in `~/.recordready-release/keys/` (directory 0700, files 0600); `update.key` is a 32-byte Ed25519 seed encoded as base64. Back up these keys securely. Partial/mismatched pairs fail closed and are never silently regenerated. Private contents never enter process arguments or repository files. Changing keys breaks the existing update trust chain.

`site/releases.json` is the retained release catalog. Generated immutable artifacts live under the ignored `site/releases/<version>/`; retain/back up these directories for subsequent delta creation. Signed applications are retained in `~/.recordready-release/builds/`. Every manifest records the actual Git HEAD and whether the source working tree was dirty. Build numbers must be positive safe integers strictly larger than all prior catalog entries. Versions and artifact paths cannot be reused.

Failures clean the unpromoted staging directory and release the local lock. A process killed without cleanup can leave `site/.release.lock`; verify that no build is running before manually removing it. If a failure occurs after immutable artifacts are promoted but before the catalog/feed completes, preserve those artifacts and run the supported recovery command after confirming no build is running:

```sh
bun scripts/release/recover-release.ts 0.1.0-beta.1
bun scripts/release/build-site.ts
```

Recovery validates the manifest, every artifact hash, ZIP/delta Ed25519 signatures against the retained public key, and monotonic catalog/feed ordering before changing metadata. It never writes release artifacts. Metadata files are each replaced atomically; recovery can be repeated if interrupted between the catalog and feed replacements. A build already present as the identical latest catalog entry is accepted so feed-only recovery works; older or changed entries are rejected. Do not rebuild into the existing version path.

Site generation uses a clean snapshot directory, then atomically replaces the `.dist` symlink, so stale files cannot enter the next upload. Existing physical `.dist` directories are migrated once to retained `.site-legacy-*` backups; snapshot and backup cleanup is deliberately manual. Failed rendering leaves the previous site available.

## Publish only after local and server review

The target is exclusively `root@39.96.16.242:/srv/recordready`. `deploy-site.ts` defaults to `~/.ssh/id_ed25519` and requires a trusted host key. Set `RECORDREADY_SSH_IDENTITY` to an available identity file and optionally `RECORDREADY_SSH_TARGET` to another authorized user at the same approved IP (other hosts are rejected). Set `RECORDREADY_SSH_CONTROL_PATH` to reuse an already authenticated temporary SSH connection instead of an identity file; credentials must never be placed in this script or repository. It does not edit DNS, TLS certificates, nginx configuration or other products' directories.

```sh
bun scripts/release/deploy-site.ts
```

Local hashes, manifest, catalog and generated feed must agree before SSH starts. A remote exclusive lock protects staging and promotion. Every uploaded file is checked against a local SHA-256 inventory; every existing release file and metadata record must remain identical. Older builds cannot replace a newer live catalog. Complete static snapshots are kept in `/srv/recordready/snapshots/<id>` and one atomic symlink replacement at `/srv/recordready/site` switches page, catalog and appcast together. `/srv/recordready/releases/` retains all published immutable release directories. Failed uploads remain in isolated staging for diagnosis; they never become the live site. No automated pruning is performed.

Bootstrap TLS in two steps: first configure the domain's DNS and install only the HTTP server block from `nginx.conf`, creating `/srv/recordready/acme` for ACME challenges. Validate with `nginx -t` before reloading, issue the domain's certificate using your existing ACME client with that webroot, then add the HTTPS block, validate again and reload. Do not install the HTTPS block before its certificate files exist; do not replace another product's virtual host. Public URLs:

- `https://recordready.qiushui.me/`
- `https://recordready.qiushui.me/updates/macos/arm64/appcast.xml`
- `https://recordready.qiushui.me/releases/<version>/<artifact>`

After publishing, fetch the live page/feed and download/check artifact hashes from HTTPS; then verify beta.1 → beta.2 on a real Mac, including update errors, restart gating and permissions. Passing script tests alone does not validate Gatekeeper, TCC or the real Sparkle installation flow. Keep the live build number monotonic: rollback application behavior via a new higher-numbered release rather than switching to an older feed snapshot.

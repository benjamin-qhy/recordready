import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { siteOrigin, type DownloadRelease, type DeltaArtifact } from './release-model';

/** Sparkle format 4 is supported by the 2.10 framework in all shipped beta builds. */
export function buildReleaseDeltas(input: { repo: string; release: DownloadRelease; previous: DownloadRelease[]; newApp: string; privateFile: string; releaseRoot: string }): DeltaArtifact[] {
  const { repo, release, previous, newApp, privateFile, releaseRoot } = input;
  const binary = join(repo, 'desktop/vendor/sparkle/bin/BinaryDelta');
  const signer = join(repo, 'desktop/vendor/sparkle/bin/sign_update');
  const deltas: DeltaArtifact[] = [];
  for (const old of previous) {
    const archive = join(repo, 'site/releases', old.version, old.zip.name);
    const original = readFileSync(archive);
    if (original.length !== old.zip.bytes || createHash('sha256').update(original).digest('hex') !== old.zip.sha256) throw new Error('DELTA_BASE_ARCHIVE_CHANGED');
    const scratch = mkdtempSync(join(tmpdir(), 'recordready-delta-'));
    const name = `RecordReady-${release.version}-from-${old.build}-macos-arm64.delta`;
    const patch = join(releaseRoot, name);
    try {
      const base = join(scratch, 'base/RecordReady.app');
      const patched = join(scratch, 'patched/RecordReady.app');
      execFileSync('ditto', ['-x', '-k', archive, join(scratch, 'base')]);
      execFileSync(binary, ['create', '--version', '4', base, newApp, patch], { stdio: 'inherit' });
      // BinaryDelta validates the source and resulting tree hashes, including permissions.
      mkdirSync(join(scratch, 'patched'));
      execFileSync(binary, ['apply', base, patched, patch], { stdio: 'inherit' });
      execFileSync('codesign', ['--verify', '--deep', '--strict', patched], { stdio: 'inherit' });
      if (statSync(patch).size >= release.zip.bytes) { rmSync(patch); continue; }
      const signature = execFileSync(signer, ['--ed-key-file', privateFile, '-p', patch], { encoding: 'utf8' }).trim();
      execFileSync(signer, ['--ed-key-file', privateFile, '--verify', patch, signature], { stdio: 'inherit' });
      const bytes = readFileSync(patch);
      deltas.push({ name, fromBuild: old.build, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), signature, url: `${siteOrigin}/releases/${release.version}/${name}` });
      console.log(`Verified delta ${old.version} -> ${release.version}: ${bytes.length} bytes`);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }
  return deltas;
}

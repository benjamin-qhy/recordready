import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { sparkleVersion, sparkleSha256, verifySparkleArchive } from './release-model';

if (process.platform !== 'darwin') throw new Error('SPARKLE_REQUIRES_MACOS');
const repo = resolve(import.meta.dir, '../..');
const vendor = join(repo, 'desktop/vendor/sparkle');
const cache = join(homedir(), '.recordready-release/cache');
mkdirSync(cache, { recursive: true, mode: 0o700 });
mkdirSync(join(repo, 'desktop/vendor'), { recursive: true });
const archive = join(cache, `Sparkle-${sparkleVersion}.tar.xz`);
if (!existsSync(archive)) {
 const partial = `${archive}.${process.pid}.part`;
 try {
  execFileSync('curl', ['-fLsS', '--retry', '3', `https://github.com/sparkle-project/Sparkle/releases/download/${sparkleVersion}/Sparkle-${sparkleVersion}.tar.xz`, '-o', partial], {stdio:'inherit'});
  verifySparkleArchive(readFileSync(partial));
  renameSync(partial, archive);
 } finally { rmSync(partial, {force:true}); }
}
verifySparkleArchive(readFileSync(archive));
// Re-extract the checksum-pinned distribution; never trust a provenance marker alone.
const staging = mkdtempSync(join(repo, 'desktop/vendor/.sparkle-'));
try {
 execFileSync('tar', ['-xf', archive, '-C', staging, './Sparkle.framework', './bin', './LICENSE'], {stdio:'inherit'});
 writeFileSync(join(staging, 'provenance.json'), JSON.stringify({sparkle:sparkleVersion,sha256:sparkleSha256,source:`https://github.com/sparkle-project/Sparkle/releases/download/${sparkleVersion}/Sparkle-${sparkleVersion}.tar.xz`},null,2)+'\n');
 rmSync(vendor, {recursive:true,force:true});
 renameSync(staging, vendor);
} finally { rmSync(staging, {recursive:true,force:true}); }
console.log(`Verified official Sparkle ${sparkleVersion}: desktop/vendor/sparkle`);

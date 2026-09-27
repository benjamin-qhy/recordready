import { createHash } from 'node:crypto';
export const siteOrigin = 'https://recordready.qiushui.me';
export const feedPath = '/updates/macos/arm64/appcast.xml';
export interface DownloadArtifact { name: string; bytes: number; sha256: string; url: string; }
export interface DeltaArtifact extends DownloadArtifact { fromBuild: number; signature: string; }
export interface DownloadRelease {
  version: string; build: number; date: string; sourceCommit: string; workingTree: boolean;
  minMacOS: string; signing: 'ad-hoc'; notes: { 'zh-CN': string; 'en-US': string };
  dmg: DownloadArtifact; zip: DownloadArtifact; signature: string; deltas?: DeltaArtifact[];
}
export const releaseVersionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:alpha|beta|rc)\.[1-9]\d*)?$/;
export function assertRelease(release: DownloadRelease) {
  if (!release || !release.notes || !release.notes['zh-CN']?.trim() || !release.notes['en-US']?.trim()
    || !/^[a-f0-9]{40}$/.test(release.sourceCommit) || typeof release.workingTree !== 'boolean'
    || !Number.isFinite(Date.parse(release.date)) || release.signing !== 'ad-hoc') throw new Error('INVALID_RELEASE_METADATA');
  if ((release.deltas?.length ?? 0) > 3) throw new Error('TOO_MANY_DELTAS');
  if (!releaseVersionPattern.test(release.version) || !Number.isSafeInteger(release.build) || release.build < 1) throw new Error('INVALID_RELEASE_VERSION');
  if (!/^\d+(\.\d+){1,2}$/.test(release.minMacOS)) throw new Error('INVALID_MINIMUM_SYSTEM');
  for (const [extension, artifact] of [['dmg', release.dmg], ['zip', release.zip]] as const) {
    const name = `RecordReady-${release.version}-macos-arm64.${extension}`;
    if (artifact.name !== name || artifact.url !== `${siteOrigin}/releases/${release.version}/${name}`
      || !Number.isSafeInteger(artifact.bytes) || artifact.bytes <= 0 || !/^[a-f0-9]{64}$/.test(artifact.sha256)) throw new Error('INVALID_RELEASE_ARTIFACT');
  }
  const bases = new Set<number>();
  for (const delta of release.deltas ?? []) {
    const name = `RecordReady-${release.version}-from-${delta.fromBuild}-macos-arm64.delta`;
    if (!Number.isSafeInteger(delta.fromBuild) || delta.fromBuild < 1 || delta.fromBuild >= release.build || bases.has(delta.fromBuild)
      || delta.name !== name || delta.url !== `${siteOrigin}/releases/${release.version}/${name}`
      || !Number.isSafeInteger(delta.bytes) || delta.bytes <= 0 || delta.bytes >= release.zip.bytes
      || !/^[a-f0-9]{64}$/.test(delta.sha256) || !/^[A-Za-z0-9+/]{86}==$/.test(delta.signature)) throw new Error('INVALID_DELTA_ARTIFACT');
    bases.add(delta.fromBuild);
  }
  if (!/^[A-Za-z0-9+/]{86}==$/.test(release.signature)) throw new Error('INVALID_UPDATE_SIGNATURE');
}
export function generateAppcast(release: DownloadRelease): string {
  assertRelease(release);
  const deltas = release.deltas?.length ? `<sparkle:deltas>${release.deltas.map(d => `<enclosure url="${d.url}" length="${d.bytes}" type="application/octet-stream" sparkle:deltaFrom="${d.fromBuild}" sparkle:edSignature="${d.signature}" />`).join('')}</sparkle:deltas>` : '';
  return `<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>RecordReady macOS</title><item><title>RecordReady ${release.version}</title><sparkle:version>${release.build}</sparkle:version><sparkle:shortVersionString>${release.version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>${release.minMacOS}</sparkle:minimumSystemVersion><enclosure url="${release.zip.url}" length="${release.zip.bytes}" type="application/octet-stream" sparkle:edSignature="${release.signature}" />${deltas}</item></channel></rss>\n`;
}

export const sparkleVersion = '2.10.0';
export const sparkleSha256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c';
export function verifySparkleArchive(bytes: Uint8Array) {
 if (createHash('sha256').update(bytes).digest('hex') !== sparkleSha256) throw new Error('SPARKLE_ARCHIVE_CHECKSUM_MISMATCH');
}
export function assertNewRelease(version: string, build: number, previous: DownloadRelease[]) {
 if (!releaseVersionPattern.test(version) || !Number.isSafeInteger(build) || build < 1 || previous.some(r => r.version === version || r.build >= build)) throw new Error('RELEASE_MUST_BE_NEW_AND_INCREASING');
}
export function assertCatalog(releases: DownloadRelease[]) {
 if (!Array.isArray(releases)) throw new Error('INVALID_RELEASE_CATALOG');
 const versions = new Set<string>();
 releases.forEach((r, i) => {
  assertRelease(r);
  if (versions.has(r.version) || (i > 0 && releases[i-1].build <= r.build)) throw new Error('INVALID_RELEASE_CATALOG');
  versions.add(r.version);
 });
}
export function verifyArtifact(bytes: Uint8Array, artifact: DownloadArtifact) {
 if (bytes.length !== artifact.bytes || createHash('sha256').update(bytes).digest('hex') !== artifact.sha256) throw new Error('ARTIFACT_BYTES_CHANGED');
}

import { test, expect } from 'bun:test';
import { assertRelease, assertNewRelease, generateAppcast, verifySparkleArchive } from './release-model';
const signature = 'A'.repeat(86) + '==';
function release(version = '0.1.0-beta.1', build = 10001): any {
 const artifact = (ext: string) => ({name: `RecordReady-${version}-macos-arm64.${ext}`,url: `https://recordready.qiushui.me/releases/${version}/RecordReady-${version}-macos-arm64.${ext}`,bytes:100,sha256:'a'.repeat(64)});
 return {version,build,date:'2026-09-27T00:00:00.000Z',sourceCommit:'b'.repeat(40),workingTree:false,minMacOS:'13.0',signing:'ad-hoc',notes:{'zh-CN':'首版','en-US':'First release'},dmg:artifact('dmg'),zip:artifact('zip'),signature,deltas:[]};
}
test('pinned Sparkle checksum rejects modified bytes', () => expect(() => verifySparkleArchive(new Uint8Array([1]))).toThrow('SPARKLE_ARCHIVE_CHECKSUM_MISMATCH'));
test('new releases require unique version and strictly increasing positive safe build', () => {
 for (const [v,b] of [['0.1.0-beta.1',10002],['0.1.0-beta.2',10001],['../bad',10002],['0.1.0-beta.2',NaN],['0.1.0-beta.2',2**53]] as const) expect(() => assertNewRelease(v,b,[release()])).toThrow();
 expect(() => assertNewRelease('0.1.0-beta.2',10002,[release()])).not.toThrow();
});
test('release artifacts are confined to exact version URLs and signed', () => {
 expect(() => assertRelease(release())).not.toThrow();
 for (const mutate of [(r:any)=>r.zip.url='https://evil.test/a.zip',(r:any)=>r.zip.name='../bad.zip',(r:any)=>r.signature='invalid',(r:any)=>r.notes['en-US']='',(r:any)=>r.sourceCommit='unknown',(r:any)=>r.date='bad']) { const r=release();mutate(r);expect(()=>assertRelease(r)).toThrow(); }
});
test('deltas have unique older builds and valid signatures', () => {
 const r=release('0.1.0-beta.2',10002);r.deltas=[{name:'RecordReady-0.1.0-beta.2-from-10001-macos-arm64.delta',url:'https://recordready.qiushui.me/releases/0.1.0-beta.2/RecordReady-0.1.0-beta.2-from-10001-macos-arm64.delta',bytes:50,sha256:'c'.repeat(64),signature,fromBuild:10001}];
 expect(()=>assertRelease(r)).not.toThrow();r.deltas.push({...r.deltas[0]});expect(()=>assertRelease(r)).toThrow();
});
test('appcast always carries full ZIP and build identity', () => {
 const xml=generateAppcast(release());expect(xml).toContain('<sparkle:version>10001</sparkle:version>');expect(xml).toContain('sparkle:edSignature="'+signature+'"');expect(xml).toContain('.zip"');expect(xml).not.toContain('.dmg"');
});

test('catalog validation rejects out of order and duplicate versions', async () => {
 const { assertCatalog } = await import('./release-model');
 expect(typeof assertCatalog).toBe('function');
 expect(()=>assertCatalog([release(), release('0.1.0-beta.2',10002)])).toThrow();
 expect(()=>assertCatalog([release('0.1.0-beta.1',10002),release()])).toThrow();
 expect(()=>assertCatalog([release('0.1.0-beta.2',10002),release()])).not.toThrow();
});
test('artifact verification detects changed bytes before publication', async () => {
 const { verifyArtifact } = await import('./release-model');
 expect(typeof verifyArtifact).toBe('function');
 expect(()=>verifyArtifact(new Uint8Array([1]),release().zip)).toThrow();
});

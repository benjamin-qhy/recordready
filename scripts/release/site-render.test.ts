import {test,expect} from 'bun:test';
test('bilingual download page safely renders notes and exact release links', async()=>{
 const module=await import('./site-render').catch(()=>({renderPage:undefined}));expect(typeof module.renderPage).toBe('function');
 const html=module.renderPage!({version:'0.1.0-beta.1',build:10001,minMacOS:'13.0',date:'2026-09-27T00:00:00Z',notes:{'zh-CN':'<script>bad()</script>','en-US':'First & best'},dmg:{url:'https://recordready.qiushui.me/release.dmg',sha256:'a'.repeat(64),bytes:100},zip:{url:'https://recordready.qiushui.me/release.zip',bytes:100}} as any);
 expect(html).toContain('下载 macOS 版');expect(html).toContain('Download for macOS');expect(html).toContain('href="https://recordready.qiushui.me/release.dmg"');expect(html).not.toContain('<script>bad()');expect(html).toContain('&lt;script&gt;');expect(html).toContain('ad-hoc');
});

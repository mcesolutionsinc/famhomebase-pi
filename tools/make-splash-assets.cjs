// Draws the boot splash's pictures (assets/splash/*.png) from the FamHomeBase mark and the Sora wordmark, on a transparent background:
//   wide.png  the logo for a landscape screen (mark left, name right)
//   tall.png  the logo for a portrait screen (mark above, name below)
//   dot.png   one of the three loading dots
// and prints the shapes (width / height of each logo), which the app's start screen uses so it draws the same logo.
//
//   node tools/make-splash-assets.cjs <the @expo-google-fonts/sora package folder> <output folder>
//
// Needs the `playwright` package (with Chromium) to be resolvable from where it is run, e.g. `cd <platform repo>/apps/engine && node <this file> ...`.
// The pictures are committed, so a release does not need any of this: run it only to change the logo.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [fontDir, outDir] = process.argv.slice(2);
if (!fontDir || !outDir) { console.error('usage: node make-splash-assets.cjs <sora package folder> <output folder>'); process.exit(2); }
const S = 240; // the mark's height in pixels in the wide logo
const INK = '#EDF1F8', GO = '#3DDC97';
const mark = `<svg viewBox="0 0 96 96" xmlns="http://www.w3.org/2000/svg"><path d="M85.6 27.2A43 43 0 1 1 68.8 10.4" fill="none" stroke="${INK}" stroke-width="4"/><circle cx="78.4" cy="17.6" r="8" fill="${GO}"/><g transform="translate(48 48) scale(.58) translate(-48 -48)"><polygon points="6,36 48,5 90,36" fill="${INK}" stroke="${INK}" stroke-width="6" stroke-linejoin="round"/><rect x="8" y="42" width="24" height="24" rx="6" fill="${INK}" opacity="0.55"/><rect x="36" y="42" width="24" height="24" rx="6" fill="${INK}"/><rect x="64" y="42" width="24" height="24" rx="6" fill="${INK}"/><rect x="8" y="70" width="24" height="24" rx="6" fill="${INK}"/><rect x="36" y="70" width="24" height="24" rx="6" fill="${GO}"/><rect x="64" y="70" width="24" height="24" rx="6" fill="${INK}" opacity="0.55"/></g></svg>`;
const word = '<span class="w"><span class="l">fam</span><span class="h">home</span><span class="b">base</span></span>';
const html = `<!doctype html><meta charset="utf-8"><style>
@font-face{font-family:SoraL;src:url("file://${path.resolve(fontDir, '300Light/Sora_300Light.ttf')}")}
@font-face{font-family:SoraS;src:url("file://${path.resolve(fontDir, '600SemiBold/Sora_600SemiBold.ttf')}")}
body{margin:0;background:transparent}
.w{color:${INK};letter-spacing:-.01em;line-height:1;white-space:nowrap;font-family:SoraS}.l{font-family:SoraL}.b{color:${GO}}
#wide{display:inline-flex;align-items:center;gap:${S * 0.3}px;padding:8px}#wide svg{width:${S}px;height:${S}px}#wide .w{font-size:${S * 0.72}px}
#tall{display:inline-flex;flex-direction:column;align-items:center;gap:${S * 0.22}px;padding:8px}#tall svg{width:${S * 1.5}px;height:${S * 1.5}px}#tall .w{font-size:${S * 0.62}px}
#dot{display:inline-block;width:${S * 0.2}px;height:${S * 0.2}px;border-radius:50%;background:${GO};margin:8px}
</style><div id="wide">${mark}${word}</div><br><div id="tall">${mark}${word}</div><br><div id="dot"></div>`;

(async () => {
  fs.mkdirSync(outDir, { recursive: true });
  const tmp = path.join(outDir, '.splash-source.html');
  fs.writeFileSync(tmp, html);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 2400, height: 1600 } });
  await page.goto('file://' + tmp);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  const shapes = {};
  for (const id of ['wide', 'tall', 'dot']) {
    const el = page.locator('#' + id);
    await el.screenshot({ path: path.join(outDir, id + '.png'), omitBackground: true });
    const box = await el.boundingBox();
    shapes[id] = { width: Math.round(box.width), height: Math.round(box.height) };
  }
  await browser.close();
  fs.unlinkSync(tmp);
  console.log(JSON.stringify(shapes));
})();

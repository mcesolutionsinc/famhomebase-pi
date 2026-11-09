// Draws the boot splash's pictures (assets/splash/*.png) from the FamHomeBase mark and the Sora wordmark, on a transparent background:
//   wide-R.png  the logo for a landscape screen (mark left, name right), already turned for a screen mounted turned R degrees (R is 0, 90, 180 or
//   tall-R.png  270; the logo is turned the other way, so it reads upright on the wall). The tall one is for a portrait screen (mark above, name below).
//               (Plymouth's own image rotation crops to the picture's old shape, so the turning is done here.)
//   dot.png     one of the three loading dots
//   ../bridge/frame-R.png  a whole 1920x1080 screen (dark, the logo in the middle at the splash's size, turned for R) that the kiosk shows
//               from the moment its screen service is up until the browser has painted, so the splash is not followed by black.
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
#dot{display:inline-block}
#wide{display:inline-flex;align-items:center;gap:${S * 0.3}px;padding:8px}#wide svg{width:${S}px;height:${S}px}#wide .w{font-size:${S * 0.72}px}
#tall{display:inline-flex;flex-direction:column;align-items:center;gap:${S * 0.22}px;padding:8px}#tall svg{width:${S * 1.5}px;height:${S * 1.5}px}#tall .w{font-size:${S * 0.62}px}
#dot{display:inline-block;width:${S * 0.2}px;height:${S * 0.2}px;border-radius:50%;background:${GO};margin:8px}
</style><div id="stage" style="position:absolute;left:600px;top:400px"></div><div id="wide" class="logo">${mark}${word}</div><div id="tall" class="logo">${mark}${word}</div><div id="dot"></div>`;

(async () => {
  fs.mkdirSync(outDir, { recursive: true });
  const tmp = path.join(outDir, '.splash-source.html');
  fs.writeFileSync(tmp, html);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 2400, height: 2400 } });
  await page.goto('file://' + tmp);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  const shapes = {};
  for (const id of ['wide', 'tall']) {
    for (const rot of [0, 90, 180, 270]) {
      // the element, turned clockwise by (360 - rot) degrees about its centre, in the middle of a big empty page
      const box = await page.evaluate(([elementId, turn]) => {
        const el = document.getElementById(elementId);
        const wrap = document.getElementById('stage');
        document.querySelectorAll('.logo').forEach((e) => (e.style.display = 'none'));
        el.style.display = elementId === 'wide' ? 'inline-flex' : 'inline-flex';
        wrap.appendChild(el);
        el.style.transform = `rotate(${turn}deg)`;
        const r = el.getBoundingClientRect();
        return { x: Math.floor(r.x), y: Math.floor(r.y), width: Math.ceil(r.width), height: Math.ceil(r.height) };
      }, [id, (360 - rot) % 360]);
      await page.screenshot({ path: path.join(outDir, `${id}-${rot}.png`), clip: box, omitBackground: true });
      shapes[`${id}-${rot}`] = { width: box.width, height: box.height };
    }
  }
  // the bridge frames: a full physical screen (1920x1080) with the logo as the splash draws it (55% of the upright screen width for the wide
  // logo, 70% for the tall one; the upright screen is turned a quarter for 90 and 270), centred and already turned
  const bridgeDir = path.join(outDir, '..', 'bridge');
  fs.mkdirSync(bridgeDir, { recursive: true });
  await page.setViewportSize({ width: 1920, height: 1080 });
  for (const rot of [0, 90, 180, 270]) {
    const quarter = rot === 90 || rot === 270;
    const id = quarter ? 'tall' : 'wide';
    const natural = shapes[`${id}-0`].width; // the logo's upright width in pixels
    const k = ((quarter ? 0.7 * 1080 : 0.55 * 1920) / natural);
    await page.evaluate(([elementId, turn, scale]) => {
      document.querySelectorAll('.logo').forEach((e) => (e.style.display = 'none'));
      let f = document.getElementById('bridge');
      if (!f) { f = document.createElement('div'); f.id = 'bridge'; document.body.appendChild(f); }
      f.style.cssText = 'position:fixed;left:0;top:0;width:1920px;height:1080px;background:#0A1327;display:flex;align-items:center;justify-content:center;overflow:hidden';
      const el = document.getElementById(elementId);
      f.appendChild(el);
      el.style.display = 'inline-flex';
      el.style.transform = `rotate(${turn}deg) scale(${scale})`;
    }, [id, (360 - rot) % 360, k]);
    await page.screenshot({ path: path.join(bridgeDir, `frame-${rot}.png`), clip: { x: 0, y: 0, width: 1920, height: 1080 } });
  }
  const dot = page.locator('#dot');
  await dot.screenshot({ path: path.join(outDir, 'dot.png'), omitBackground: true });
  const d = await dot.boundingBox();
  shapes.dot = { width: Math.round(d.width), height: Math.round(d.height) };
  await browser.close();
  fs.unlinkSync(tmp);
  console.log(JSON.stringify(shapes));
})();

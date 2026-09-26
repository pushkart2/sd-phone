import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../../web/package.json', import.meta.url));
const { chromium } = require('playwright');
const source = new URL('./vibrant.html', import.meta.url);
const output = new URL('./screenshots/vibrant/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, channel: 'chrome' });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1150 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const checkContrast = async phone => {
    const samples = await phone.locator('.screen').evaluate(screen => {
      const luminance = color => {
        const bytes = color.startsWith('#') ? color.slice(1).match(/../g).map(hex=>parseInt(hex,16)) : color.match(/[\d.]+/g).slice(0,3).map(Number);
        const rgb = bytes.map(byte=>byte/255).map(n=>n<=.04045?n/12.92:((n+.055)/1.055)**2.4);
        return .2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];
      };
      const ratio = (a,b) => (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
      const style = getComputedStyle(screen);
      const value = key => luminance(style.getPropertyValue(key).trim());
      const samples = [['Text',ratio(value('--ink'),value('--bg')),4.5],['Secondary',ratio(value('--muted'),value('--bg')),4.5],['Surface text',ratio(value('--ink'),value('--surface')),4.5],['Secondary surface',ratio(value('--muted'),value('--surface')),4.5],['Action text',ratio(value('--on-accent'),value('--accent')),4.5]];
      screen.querySelectorAll('.app-mark').forEach(mark=>{
        const computed=getComputedStyle(mark);
        samples.push([mark.closest('button').getAttribute('aria-label'),ratio(luminance(computed.color),luminance(computed.backgroundColor)),3]);
      });
      return samples;
    });
    const failed = samples.filter(([,ratio,minimum])=>ratio<minimum);
    if(failed.length) throw new Error(`Contrast failed: ${JSON.stringify(failed)}`);
  };
  await page.goto(source.href);
  for (const screen of ['home', 'chat', 'bank', 'music']) {
    await page.locator(`[data-page="${screen}"]`).click();
    await page.screenshot({ path: fileURLToPath(new URL(`${screen}-comparison.png`, output)), fullPage: true });
  }
  for (const id of ['coast', 'current', 'tempo']) {
    await page.setViewportSize({ width: 620, height: 1150 });
    await page.goto(`${source.href}?concept=${id}`);
    const phone = page.locator(`[data-design="${id}"]`);
    await checkContrast(phone);
    await page.screenshot({ path: fileURLToPath(new URL(`${id}.png`, output)), fullPage: true });
    if (await phone.locator('[data-app-tile]').count() !== 12) throw new Error(`${id}: home grid missing`);
    await phone.locator('.home [data-open="bank"]').click();
    if (await phone.locator('.balance').textContent() !== '$12,480.00') throw new Error(`${id}: home icon launch failed`);
    await phone.locator('.dock [data-open="messages"]').click();
    await phone.locator('[data-contact="Alex Morgan"]').click();
    await phone.locator('.composer input').fill('<Meet at Benny’s>');
    await phone.locator('.composer button').click();
    if (await phone.locator('.bubble.sent').last().textContent() !== '<Meet at Benny’s>') throw new Error(`${id}: message handling failed`);
    await phone.locator('.composer input').fill('Keep this draft');
    const mode = await phone.locator('.screen').getAttribute('data-mode');
    await phone.locator('.mode-button').click();
    if (await phone.locator('.screen').getAttribute('data-mode') === mode) throw new Error(`${id}: mode did not change`);
    if (await phone.locator('.composer input').inputValue() !== 'Keep this draft') throw new Error(`${id}: draft lost on mode change`);
    await phone.locator('.dock [data-open="apps"]').click();
    await phone.locator('[data-search]').fill('no such app');
    if (!await phone.locator('[data-empty]').isVisible()) throw new Error(`${id}: empty search missing`);
    await phone.locator('[data-search]').fill('music');
    if (await phone.locator('[data-app-tile]:visible').count() !== 1) throw new Error(`${id}: search failed`);
    await phone.locator('[data-app-tile]:visible').click();
    await phone.locator('[data-play]').click();
    if (await phone.locator('[data-play]').getAttribute('aria-label') !== 'Pause music') throw new Error(`${id}: player failed`);
    await phone.locator('.dock [data-open="apps"]').click();
    await phone.locator('[data-open="settings"]').click();
    await phone.locator('.settings-row [data-mode]').click();
    if (await phone.locator('.screen').getAttribute('data-mode') !== mode) throw new Error(`${id}: settings appearance failed`);
    await phone.locator('.mode-button').click();
    await phone.locator('.dock [data-open="home"]').click();
    await checkContrast(phone);
    await page.screenshot({ path: fileURLToPath(new URL(`${id}-alternate.png`, output)), fullPage: true });
  }
  for (const width of [1440, 1100, 900, 850, 390]) {
    await page.setViewportSize({ width, height: 1150 });
    await page.goto(source.href);
    if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error(`Horizontal page overflow at ${width}px`);
    if (await page.locator('.content').evaluateAll(elements => elements.some(el => el.scrollWidth > el.clientWidth))) throw new Error(`Horizontal phone overflow at ${width}px`);
  }
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('Captured home, messages, banking, and music comparisons plus each palette in both appearances. Icon launches, messaging, escaping, search, playback, draft preservation, appearance, and responsive checks passed.');
} finally {
  await browser.close();
}

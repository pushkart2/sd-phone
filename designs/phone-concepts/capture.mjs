// Uses the repository's existing Playwright dependency. No packages are installed.
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../../web/package.json', import.meta.url));
const { chromium } = require('playwright');
const screenshots = new URL('./screenshots/', import.meta.url);
const source = new URL('./index.html', import.meta.url);
await mkdir(screenshots, { recursive: true });
const browser = await chromium.launch({ headless: true, channel: 'chrome' });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${source.href}?collection=original`);
  await page.screenshot({ path: fileURLToPath(new URL('comparison.png', screenshots)), fullPage: true });
  await page.setViewportSize({ width: 1200, height: 1140 });
  await page.goto(source.href);
  await page.screenshot({ path: fileURLToPath(new URL('paper-mosaic-comparison.png', screenshots)), fullPage: true });
  const contrast = await page.locator('.hybrid').evaluateAll(elements => {
    const luminance = hex => {
      const values = hex.trim().match(/[0-9a-f]{2}/gi).map(value => parseInt(value, 16) / 255)
        .map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
      return .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
    };
    const ratio = (a, b) => (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
    return elements.map(el => {
      const style = getComputedStyle(el);
      const bg = luminance(style.getPropertyValue('--bg'));
      const surface = luminance(style.getPropertyValue('--surface'));
      const ink = luminance(style.getPropertyValue('--ink'));
      const muted = luminance(style.getPropertyValue('--muted'));
      const accent = luminance(style.getPropertyValue('--accent'));
      return { mode: el.dataset.theme, text: ratio(ink, bg), secondary: ratio(muted, bg), accent: ratio(accent, bg), surfaceText: ratio(ink, surface), surfaceSecondary: ratio(muted, surface) };
    });
  });
  for (const sample of contrast) {
    if (Object.entries(sample).some(([key,value]) => key !== 'mode' && value < 4.5)) throw new Error(`Text contrast below 4.5:1: ${JSON.stringify(sample)}`);
  }
  console.log('Palette text contrast:', JSON.stringify(contrast));
  for (const id of ['signal', 'paper', 'mosaic', 'paper-mosaic-light', 'paper-mosaic-dark']) {
    await page.setViewportSize({ width: 620, height: 1120 });
    await page.goto(`${source.href}?concept=${id}`);
    await page.screenshot({ path: fileURLToPath(new URL(`${id}.png`, screenshots)), fullPage: true });
    const phone = page.locator(`[data-design="${id}"]`);
    await phone.locator('.phone-nav [data-open="messages"]').click();
    await phone.locator('[data-chat="Alex Morgan"]').click();
    await phone.locator('.composer input').fill('See you in five.');
    await phone.locator('.composer button').click();
    if (await phone.locator('.chat-message.sent').last().textContent() !== 'See you in five.') throw new Error(`${id}: message did not send`);
    if (id.startsWith('paper-mosaic')) {
      const initialTheme = await phone.locator('.screen').getAttribute('data-theme');
      const otherTheme = initialTheme === 'light' ? 'dark' : 'light';
      await phone.locator('.composer input').fill('Draft stays here');
      await phone.locator(`.theme-picker [data-theme-choice="${otherTheme}"]`).click();
      if (await phone.locator('.screen').getAttribute('data-theme') !== otherTheme) throw new Error(`${id}: theme failed`);
      if (await phone.locator('.composer input').inputValue() !== 'Draft stays here') throw new Error(`${id}: draft lost on theme change`);
      if (await phone.locator('.chat-message.sent').last().textContent() !== 'See you in five.') throw new Error(`${id}: conversation lost on theme change`);
      await phone.locator(`.theme-picker [data-theme-choice="${initialTheme}"]`).click();
      await phone.locator('.composer input').fill('');
    }
    await page.screenshot({ path: fileURLToPath(new URL(`${id}-messages.png`, screenshots)), fullPage: true });
    await phone.locator('.phone-nav [data-open="apps"]').click();
    await phone.locator('[data-search]').fill('bank');
    if (await phone.locator('.app-list-item:visible').count() !== 1) throw new Error(`${id}: app search failed`);
    await phone.locator('.app-list-item:visible').click();
    if (await phone.locator('.balance').textContent() !== '$12,480.00') throw new Error(`${id}: bank failed`);
    await phone.locator('.phone-nav [data-open="apps"]').click();
    await phone.locator('[data-open="music"]').click();
    await phone.locator('[data-play]').click();
    if (await phone.locator('[data-play]').getAttribute('aria-label') !== 'Pause music') throw new Error(`${id}: player failed`);
    if (id.startsWith('paper-mosaic')) {
      await phone.locator('.phone-nav [data-open="apps"]').click();
      await phone.locator('[data-open="settings"]').click();
      await phone.locator('.settings-theme [data-theme-choice="dark"]').click();
      if (await phone.locator('.screen').getAttribute('data-theme') !== 'dark') throw new Error(`${id}: settings theme control failed`);
      if (await phone.locator('.settings-theme [aria-pressed="true"]').textContent() !== 'Dark') throw new Error(`${id}: selected theme label failed`);
    }
    await phone.locator('.phone-nav [data-open="home"]').click();
  }
  for (const width of [1440, 1100, 900, 850, 390]) {
    await page.setViewportSize({ width, height: 1100 });
    for (const query of ['', '?collection=original']) {
      await page.goto(`${source.href}${query}`);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow) throw new Error(`Horizontal page overflow at ${width}px (${query})`);
      const contentOverflow = await page.locator('.screen-content').evaluateAll(elements => elements.some(el => el.scrollWidth > el.clientWidth));
      if (contentOverflow) throw new Error(`Horizontal phone overflow at ${width}px (${query})`);
    }
  }
  await page.setViewportSize({ width: 1200, height: 1140 });
  await page.goto(source.href);
  for (const id of ['paper-mosaic-light', 'paper-mosaic-dark']) {
    const phone = page.locator(`[data-design="${id}"]`);
    await phone.locator('.phone-nav [data-open="messages"]').click();
    await phone.locator('[data-chat="Alex Morgan"]').click();
  }
  await page.screenshot({ path: fileURLToPath(new URL('paper-mosaic-messages-comparison.png', screenshots)), fullPage: true });
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('Captured original studies and Paper × Mosaic light/dark homescreens and messages. Navigation, messaging, search, player, contrast, theme switching, draft preservation, and responsive checks passed.');
} finally {
  await browser.close();
}

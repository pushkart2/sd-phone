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
  await page.goto(source.href);
  await page.screenshot({ path: fileURLToPath(new URL('comparison.png', screenshots)), fullPage: true });
  for (const id of ['signal', 'paper', 'mosaic']) {
    await page.setViewportSize({ width: 620, height: 1120 });
    await page.goto(`${source.href}?concept=${id}`);
    await page.screenshot({ path: fileURLToPath(new URL(`${id}.png`, screenshots)), fullPage: true });
    const phone = page.locator(`[data-design="${id}"]`);
    await phone.locator('.phone-nav [data-open="messages"]').click();
    await phone.locator('[data-chat="Alex Morgan"]').click();
    await phone.locator('.composer input').fill('See you in five.');
    await phone.locator('.composer button').click();
    if (await phone.locator('.chat-message.sent').last().textContent() !== 'See you in five.') throw new Error(`${id}: message did not send`);
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
    await phone.locator('.phone-nav [data-open="home"]').click();
  }
  for (const width of [1440, 1100, 900, 850, 390]) {
    await page.setViewportSize({ width, height: 1100 });
    await page.goto(source.href);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
    if (overflow) throw new Error(`Horizontal page overflow at ${width}px`);
    const contentOverflow = await page.locator('.screen-content').evaluateAll(elements => elements.some(el => el.scrollWidth > el.clientWidth));
    if (contentOverflow) throw new Error(`Horizontal phone overflow at ${width}px`);
  }
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('Captured comparison, three homescreens, and three message screens. All navigation, message, search, player, and responsive checks passed.');
} finally {
  await browser.close();
}

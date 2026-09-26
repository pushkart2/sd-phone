import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../../web/package.json', import.meta.url));
const { chromium } = require('playwright');
const source = new URL('./vibrant.html', import.meta.url);
const output = new URL('./screenshots/vibrant/', import.meta.url);
const registry = await readFile(new URL('../../web/src/shell/appRegistry.tsx', import.meta.url), 'utf8');
const registeredApps = [...registry.split('const APP_REGISTRY = {')[1].split('satisfies Record')[0].matchAll(/^\s+(\w+):\s*(?:entry\(|\{)/gm)].map(match => match[1]).sort();
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, channel: 'chrome' });
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1150 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const checkHomeGrid = async () => {
    const layouts = await page.locator('.home:visible').evaluateAll(homes => homes.map(home => {
      const content = home.closest('.content').getBoundingClientRect();
      const pager = home.querySelector('.home-pager'), grids = [...pager.querySelectorAll('.app-grid')];
      return { gridGap: content.bottom - home.querySelector('.page-dots').getBoundingClientRect().bottom, gap: parseFloat(getComputedStyle(grids[0]).rowGap), iconSize: home.querySelector('.app-mark').getBoundingClientRect().width, horizontal: pager.scrollWidth > pager.clientWidth, vertical: pager.scrollHeight > pager.clientHeight + 1 || grids.some(grid => grid.scrollHeight > grid.clientHeight + 1), overflow: home.scrollHeight > home.closest('.content').clientHeight, apps: [...pager.querySelectorAll('[data-app-tile]')].map(tile => tile.dataset.open).sort() };
    }));
    if (layouts.some(layout => layout.gridGap > 25 || layout.gap > 23 || layout.iconSize > 53 || !layout.horizontal || layout.vertical || layout.overflow || JSON.stringify(layout.apps) !== JSON.stringify(registeredApps))) throw new Error(`Paged home grid or app inventory mismatch: ${JSON.stringify(layouts)}`);
  };
  const waitForHomePage = async (phone, index) => {
    await page.waitForFunction(({id,index}) => {
      const phone = document.querySelector(`[data-design="${id}"]`), pager = phone.querySelector('.home-pager');
      return phone.querySelector(`[data-home-page="${index}"]`).getAttribute('aria-current') === 'true' && Math.abs(pager.scrollLeft-index*pager.clientWidth)<1;
    }, {id:await phone.getAttribute('data-design'),index});
  };
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
    await checkHomeGrid();
    const pagerBox=await phone.locator('.home-pager').boundingBox();
    await page.mouse.move(pagerBox.x+pagerBox.width*.85,pagerBox.y+28);
    await page.mouse.down();
    await page.mouse.move(pagerBox.x+pagerBox.width*.15,pagerBox.y+28,{steps:12});
    await page.mouse.up();
    await waitForHomePage(phone,1);
    if (!await phone.locator('.home').count()) throw new Error(`${id}: drag accidentally opened an app`);
    await phone.locator('.home-pager').focus();
    await page.keyboard.press('ArrowLeft');
    await waitForHomePage(phone,0);
    await phone.locator('[data-home-page]').last().click();
    await waitForHomePage(phone,await phone.locator('[data-home-page]').count()-1);
    await phone.locator('.home [data-open="racing"]').click();
    if (await phone.locator('.app-header h3').textContent() !== 'Racing') throw new Error(`${id}: last app is inaccessible`);
    await phone.locator('.app-header [data-open="home"]').click();
    if (await phone.locator('[data-home-page][aria-current="true"]').getAttribute('data-home-page') !== String(await phone.locator('[data-home-page]').count()-1)) throw new Error(`${id}: home page position lost on return`);
    await phone.locator('[data-home-page="0"]').click();
    await waitForHomePage(phone,0);
    await phone.locator('.home [data-open="bank"]').click();
    if (await phone.locator('.balance').textContent() !== '$12,480.00') throw new Error(`${id}: home icon launch failed`);
    await phone.locator('.app-header [data-open="home"]').click();
    await phone.locator('.home [data-open="messages"]').click();
    await phone.locator('[data-contact="Alex Morgan"]').click();
    await phone.locator('.composer input').fill('<Meet at Benny’s>');
    await phone.locator('.composer button').click();
    if (await phone.locator('.bubble.sent').last().textContent() !== '<Meet at Benny’s>') throw new Error(`${id}: message handling failed`);
    await phone.locator('.composer input').fill('Keep this draft');
    const mode = await phone.locator('.screen').getAttribute('data-mode');
    await phone.locator('.mode-button').click();
    if (await phone.locator('.screen').getAttribute('data-mode') === mode) throw new Error(`${id}: mode did not change`);
    if (await phone.locator('.composer input').inputValue() !== 'Keep this draft') throw new Error(`${id}: draft lost on mode change`);
    await phone.locator('.app-header [data-open="messages"]').click();
    await phone.locator('.app-header [data-open="home"]').click();
    await phone.locator('.home [data-open="apps"]').click();
    await phone.locator('[data-search]').fill('no such app');
    if (!await phone.locator('[data-empty]').isVisible()) throw new Error(`${id}: empty search missing`);
    await phone.locator('[data-search]').fill('voice');
    if (await phone.locator('[data-app-tile]:visible').count() !== 1 || await phone.locator('[data-app-tile]:visible').getAttribute('data-open') !== 'voicememos') throw new Error(`${id}: added apps missing from search`);
    await phone.locator('[data-search]').fill('music');
    if (await phone.locator('[data-app-tile]:visible').count() !== 1) throw new Error(`${id}: search failed`);
    await phone.locator('[data-app-tile]:visible').click();
    await phone.locator('[data-play]').click();
    if (await phone.locator('[data-play]').getAttribute('aria-label') !== 'Pause music') throw new Error(`${id}: player failed`);
    await phone.locator('.app-header [data-open="home"]').click();
    await phone.locator('.home [data-open="apps"]').click();
    await phone.locator('[data-open="settings"]').click();
    await phone.locator('.settings-row [data-mode]').click();
    if (await phone.locator('.screen').getAttribute('data-mode') !== mode) throw new Error(`${id}: settings appearance failed`);
    await phone.locator('.mode-button').click();
    await phone.locator('.app-header [data-open="home"]').click();
    await checkContrast(phone);
    await page.screenshot({ path: fileURLToPath(new URL(`${id}-alternate.png`, output)), fullPage: true });
  }
  for (const width of [1440, 1100, 900, 850, 390]) {
    await page.setViewportSize({ width, height: 1150 });
    await page.goto(source.href);
    await checkHomeGrid();
    if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error(`Horizontal page overflow at ${width}px`);
    if (await page.locator('.content').evaluateAll(elements => elements.some(el => el.scrollWidth > el.clientWidth))) throw new Error(`Horizontal phone overflow at ${width}px`);
  }
  await page.setViewportSize({ width: 1200, height: 1150 });
  await page.goto(`${source.href}?study=coast`);
  await checkHomeGrid();
  await page.screenshot({ path: fileURLToPath(new URL('coast-modes.png', output)), fullPage: true });
  for (const id of ['coast','coast-night']) {
    const phone=page.locator(`[data-design="${id}"]`);
    await phone.locator('[data-home-page="1"]').click();
    await waitForHomePage(phone,1);
  }
  await page.screenshot({ path: fileURLToPath(new URL('coast-more-apps.png', output)), fullPage: true });
  for (const id of ['coast', 'coast-night']) {
    const phone = page.locator(`[data-design="${id}"]`);
    await checkContrast(phone);
    await phone.locator('[data-home-page="0"]').click();
    await waitForHomePage(phone,0);
    await phone.locator('.home [data-open="bank"]').click();
    if (await phone.locator('.balance').textContent() !== '$12,480.00') throw new Error(`${id}: paired preview failed`);
  }
  await page.setViewportSize({ width: 390, height: 1150 });
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error('Paired preview overflows on mobile');
  const touchContext = await browser.newContext({ hasTouch:true, isMobile:true, viewport:{width:390,height:1150} });
  try {
    const touchPage=await touchContext.newPage();
    touchPage.on('pageerror',error=>errors.push(error.message));
    await touchPage.goto(`${source.href}?concept=coast`);
    const session=await touchContext.newCDPSession(touchPage);
    const box=await touchPage.locator('[data-design="coast"] .home-pager').boundingBox();
    const swipe=async (from,to,target)=>{
      const y=box.y+box.height*.5;
      await session.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:from,y}]});
      for(let step=1;step<=10;step++) await session.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:from+(to-from)*step/10,y}]});
      await session.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
      await touchPage.waitForFunction(index=>{
        const pager=document.querySelector('[data-design="coast"] .home-pager');
        return pager && Math.abs(pager.scrollLeft-index*pager.clientWidth)<1 && document.querySelector(`[data-home-page="${index}"]`).getAttribute('aria-current')==='true';
      },target);
    };
    await swipe(box.x+box.width*.85,box.x+box.width*.15,1);
    await swipe(box.x+box.width*.15,box.x+box.width*.85,0);
    if(await touchPage.locator('[data-design="coast"] .content').evaluate(el=>el.scrollTop!==0)) throw new Error('Touch swipe scrolled home vertically');
  } finally { await touchContext.close(); }
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('Captured home pages, messages, banking, and music comparisons plus each palette in both appearances. Touch swipe, mouse swipe, page dots, keyboard paging, page restoration, app inventory, icon launches, messaging, search, playback, appearance, and responsive checks passed.');
} finally {
  await browser.close();
}

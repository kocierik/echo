const puppeteer = require('puppeteer');
(async () => {
  const browser = await puppeteer.launch({executablePath: process.env.CHROME_PATH, args: ['--no-sandbox','--allow-file-access-from-files']});
  const page = await browser.newPage();
  await page.setViewport({width: 1024, height: 1024});
  await page.goto('file:///work/icon.svg');
  await page.screenshot({path: '/work/icon-1024.png'});
  await browser.close();
})();

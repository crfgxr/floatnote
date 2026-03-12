const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const CAPTURE_DIR = path.join(__dirname, 'captures');
const USER_DATA_DIR = path.join(__dirname, '.chrome-profile');
fs.mkdirSync(CAPTURE_DIR, { recursive: true });

const requests = [];
let requestId = 0;

(async () => {
  // Use persistent context to avoid bot detection and keep login session
  const context = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    viewport: { width: 1400, height: 900 },
    args: [
      '--window-size=1400,900',
      '--disable-blink-features=AutomationControlled',
    ],
    ignoreDefaultArgs: ['--enable-automation'],
  });

  const page = context.pages()[0] || await context.newPage();

  // Capture ALL requests (including Web Workers)
  page.on('request', (request) => {
    const url = request.url();
    if (!url.includes('evernote')) return;
    if (url.match(/\.(js|css|woff2?|png|jpg|gif|svg|ico)(\?|$)/i)) return;

    const id = ++requestId;
    const entry = {
      id,
      timestamp: new Date().toISOString(),
      method: request.method(),
      url,
      headers: request.headers(),
      postData: request.postData() || null,
      resourceType: request.resourceType(),
      isFromWorker: request.frame() === null,
    };
    requests.push(entry);

    const tag = entry.isFromWorker ? '[WORKER]' : '[MAIN]';
    const short = url.length > 100 ? url.substring(0, 100) + '...' : url;
    console.log(`${tag} >> ${request.method()} ${short}`);
  });

  page.on('response', async (response) => {
    const url = response.url();
    if (!url.includes('evernote')) return;
    if (url.match(/\.(js|css|woff2?|png|jpg|gif|svg|ico)(\?|$)/i)) return;

    const matchingReq = [...requests].reverse().find(r => r.url === url && !r.response);
    if (!matchingReq) return;

    matchingReq.response = {
      status: response.status(),
      headers: response.headers(),
    };

    try {
      const body = await response.body();
      const text = body.toString('utf-8');
      if (text.length > 0) {
        matchingReq.response.body = text.substring(0, 100000);
        try {
          JSON.parse(text);
          matchingReq.response.bodyType = 'json';
        } catch {
          const nonPrintable = [...text.substring(0, 200)].filter(c => c.charCodeAt(0) < 32 && c !== '\n' && c !== '\r' && c !== '\t').length;
          matchingReq.response.bodyType = nonPrintable > 10 ? 'binary' : 'text';
        }
      }
    } catch (e) {
      matchingReq.response.bodyError = e.message;
    }
  });

  console.log('\n========================================');
  console.log('  Evernote Network Capture (anti-bot)');
  console.log('========================================');
  console.log('Using persistent profile to avoid captcha.');
  console.log('1. Log in (or you may already be logged in)');
  console.log('2. Browse: open notes, switch notebooks,');
  console.log('   edit notes, search, create notes');
  console.log('3. Close browser window when done');
  console.log('========================================\n');

  await page.goto('https://www.evernote.com/client/web');

  await new Promise((resolve) => {
    context.on('close', resolve);
    process.on('SIGINT', () => resolve());
  });

  const cookies = await context.cookies().catch(() => []);
  const ts = Date.now();

  fs.writeFileSync(
    path.join(CAPTURE_DIR, `capture_${ts}.json`),
    JSON.stringify({ capturedAt: new Date().toISOString(), cookies, totalRequests: requests.length, requests }, null, 2)
  );

  const apiRequests = requests.map(r => ({
    id: r.id,
    method: r.method,
    url: r.url,
    isFromWorker: r.isFromWorker,
    postData: r.postData?.substring(0, 2000),
    status: r.response?.status,
    bodyType: r.response?.bodyType,
    responsePreview: r.response?.body?.substring(0, 500),
  }));
  fs.writeFileSync(
    path.join(CAPTURE_DIR, `api_summary_${ts}.json`),
    JSON.stringify(apiRequests, null, 2)
  );

  fs.writeFileSync(
    path.join(CAPTURE_DIR, `cookies_${ts}.json`),
    JSON.stringify(cookies, null, 2)
  );

  const workerReqs = requests.filter(r => r.isFromWorker).length;
  const mainReqs = requests.filter(r => !r.isFromWorker).length;
  console.log(`\n--- Summary ---`);
  console.log(`Total API requests: ${requests.length}`);
  console.log(`  From Web Worker: ${workerReqs}`);
  console.log(`  From Main thread: ${mainReqs}`);
  console.log(`Cookies: ${cookies.length}`);
  console.log(`Files saved to: captures/`);

  await context.close().catch(() => {});
  process.exit(0);
})();

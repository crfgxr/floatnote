const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const USER_DATA_DIR = path.join(__dirname, '.chrome-profile');
const TOKEN_FILE = path.join(__dirname, '.auth.json');

(async () => {
  const context = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    viewport: { width: 1400, height: 900 },
    args: ['--disable-blink-features=AutomationControlled'],
    ignoreDefaultArgs: ['--enable-automation'],
  });

  const page = context.pages()[0] || await context.newPage();

  let authData = null;

  // Intercept the auth token response
  page.on('response', async (response) => {
    const url = response.url();

    // Capture the OAuth token exchange
    if (url.includes('accounts.evernote.com/auth/token')) {
      try {
        const body = await response.json();
        if (body.access_token) {
          // Decode JWT to get mono_authn_token
          const payload = JSON.parse(
            Buffer.from(body.access_token.split('.')[1], 'base64').toString()
          );
          authData = {
            accessToken: body.access_token,
            refreshToken: body.refresh_token,
            monoToken: payload.mono_authn_token,
            userId: payload.evernote_user_id,
            clientId: payload.client_id,
            expiresAt: new Date(payload.exp * 1000).toISOString(),
            savedAt: new Date().toISOString(),
          };

          // Extract shard from mono token (S=sXX:...)
          const shardMatch = authData.monoToken.match(/S=(s\d+)/);
          if (shardMatch) authData.shard = shardMatch[1];

          fs.writeFileSync(TOKEN_FILE, JSON.stringify(authData, null, 2));
          console.log('\n=== Auth token captured! ===');
          console.log(`User ID: ${authData.userId}`);
          console.log(`Shard: ${authData.shard}`);
          console.log(`Expires: ${authData.expiresAt}`);
          console.log(`Saved to: .auth.json`);
          console.log('You can close the browser now.\n');
        }
      } catch (e) {
        // ignore
      }
    }
  });

  // Check if we already have a valid token
  if (fs.existsSync(TOKEN_FILE)) {
    const existing = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf-8'));
    if (new Date(existing.expiresAt) > new Date()) {
      console.log('Existing token still valid until', existing.expiresAt);
      console.log('Opening Evernote to refresh token...');
    }
  }

  console.log('\n========================================');
  console.log('  Evernote Login - Token Extractor');
  console.log('========================================');
  console.log('Log in to Evernote. Token will be');
  console.log('captured automatically on login.');
  console.log('Close browser when done.');
  console.log('========================================\n');

  await page.goto('https://www.evernote.com/client/web');

  await new Promise((resolve) => {
    context.on('close', resolve);
    process.on('SIGINT', () => resolve());
  });

  if (authData) {
    console.log('Auth saved successfully!');
  } else if (fs.existsSync(TOKEN_FILE)) {
    console.log('Using previously saved auth token.');
  } else {
    console.log('No auth token captured. Try again.');
  }

  await context.close().catch(() => {});
  process.exit(0);
})();

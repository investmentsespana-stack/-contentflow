import { test, expect } from '@playwright/test';

// Runtime evidence test for panel_qa_v1_browser.
test('panel_qa_v1_browser: production loads without fatal browser errors', async ({ page }) => {
  const fatal: string[] = [];
  page.on('pageerror', err => fatal.push(`pageerror: ${err.message}`));
  page.on('console', msg => {
    if (msg.type() === 'error') fatal.push(`console: ${msg.text()}`);
  });

  const response = await page.goto('/', { waitUntil: 'domcontentloaded' });
  expect(response, 'main document response').not.toBeNull();
  expect(response!.status(), 'main document status').toBeLessThan(400);
  await expect(page.locator('body')).toBeVisible();
  await expect(page.locator('body')).not.toHaveText('');

  await page.waitForLoadState('networkidle').catch(() => undefined);

  expect(fatal, `fatal browser errors: ${fatal.join(' | ')}`).toEqual([]);
});

import { test, expect } from '@playwright/test';

// Runtime evidence test for panel_qa_v1_browser.
// The production project intentionally exposes explicit static/API routes and does
// not define a root document. Validate a declared production route rather than
// treating the expected root 404 as an application failure.
test('panel_qa_v1_browser: production loads without fatal browser errors', async ({ page }) => {
  const fatal: string[] = [];
  page.on('pageerror', err => fatal.push(`pageerror: ${err.message}`));
  page.on('console', msg => {
    if (msg.type() === 'error') fatal.push(`console: ${msg.text()}`));
  });

  const targetPath = process.env.CONTENTFLOW_QA_PATH ?? '/escuela-digital';
  const response = await page.goto(targetPath, { waitUntil: 'domcontentloaded' });
  expect(response, 'main document response').not.toBeNull();
  expect(response!.status(), 'main document status').toBeLessThan(400);
  await expect(page.locator('body')).toBeVisible();
  await expect(page.locator('body')).not.toHaveText('');

  await page.waitForLoadState('networkidle').catch(() => undefined);

  expect(fatal, `fatal browser errors: ${fatal.join(' | ')}`).toEqual([]);
});

export default async function handler(req, res) {
  const { code, state, error, error_description: errorDescription } = req.query || {};

  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');

  if (error) {
    return res.status(400).send(`<!doctype html><html><body><h1>Meta authorization not completed</h1><p>${escapeHtml(errorDescription || error)}</p></body></html>`);
  }

  if (!code) {
    return res.status(400).send('<!doctype html><html><body><h1>Missing authorization code</h1><p>Return to the Meta authorization flow and try again.</p></body></html>');
  }

  // Token exchange is intentionally not performed here until META_APP_ID,
  // META_APP_SECRET and state validation are configured securely in runtime.
  const safeState = state ? 'received' : 'missing';
  return res.status(200).send(`<!doctype html><html><body><h1>Meta callback reached</h1><p>Authorization code received securely.</p><p>State: ${safeState}</p><p>You may close this window.</p></body></html>`);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

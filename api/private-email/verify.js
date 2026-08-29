import { verifyPrivateEmailConnection } from '../../src/platform/private-email-connector.mjs';
import { verifyImap, verifySmtp } from '../../src/platform/private-email-node-adapters.mjs';

// Production verification endpoint for the Cygnus private mailbox.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ ok: false, error: 'method_not_allowed' });
  }

  try {
    const receipt = await verifyPrivateEmailConnection({}, { verifyImap, verifySmtp });
    return res.status(receipt.status === 'connected' ? 200 : 503).json({
      schema: receipt.schema,
      status: receipt.status,
      imapStatus: receipt.imapStatus,
      smtpStatus: receipt.smtpStatus,
      checkedAt: receipt.checkedAt,
    });
  } catch (error) {
    return res.status(503).json({
      schema: 'nexo.private_email.connection.v1',
      status: 'failed',
      error: error?.message || 'private_email_verification_failed',
    });
  }
}

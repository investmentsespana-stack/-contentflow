import test from 'node:test';
import assert from 'node:assert/strict';
import {
  getPrivateEmailConfig,
  safePrivateEmailReceipt,
  verifyPrivateEmailConnection,
} from '../src/platform/private-email-connector.mjs';

test('builds secure Namecheap Private Email config without exposing password', () => {
  const config = getPrivateEmailConfig({
    PRIVATE_EMAIL_ADDRESS: 'social@example.com',
    PRIVATE_EMAIL_PASSWORD: 'secret-value',
    PRIVATE_EMAIL_IMAP_HOST: 'mail.privateemail.com',
    PRIVATE_EMAIL_IMAP_PORT: '993',
    PRIVATE_EMAIL_SMTP_HOST: 'mail.privateemail.com',
    PRIVATE_EMAIL_SMTP_PORT: '465',
  });

  assert.equal(config.address, 'social@example.com');
  assert.equal(config.imap.port, 993);
  assert.equal(config.smtp.port, 465);
  assert.equal(config.imap.secure, true);
  assert.equal(config.smtp.secure, true);

  const receipt = safePrivateEmailReceipt(config);
  assert.equal(receipt.password, undefined);
  assert.match(receipt.passwordFingerprint, /^sha256:/);
});

test('verifies IMAP and SMTP in parallel and returns a safe receipt', async () => {
  const env = {
    PRIVATE_EMAIL_ADDRESS: 'social@example.com',
    PRIVATE_EMAIL_PASSWORD: 'secret-value',
  };

  const receipt = await verifyPrivateEmailConnection({ env }, {
    verifyImap: async () => ({ ok: true }),
    verifySmtp: async () => ({ ok: true }),
  });

  assert.equal(receipt.status, 'connected');
  assert.equal(receipt.imapStatus, 'connected');
  assert.equal(receipt.smtpStatus, 'connected');
  assert.equal(receipt.address, 'social@example.com');
  assert.equal('password' in receipt, false);
});

test('fails closed when password is missing', () => {
  assert.throws(
    () => getPrivateEmailConfig({ PRIVATE_EMAIL_ADDRESS: 'social@example.com' }),
    /private_email_password_required/,
  );
});

import crypto from 'node:crypto';

const DEFAULT_HOST = 'mail.privateemail.com';
const DEFAULT_IMAP_PORT = 993;
const DEFAULT_SMTP_PORT = 465;

function required(value, name) {
  if (!value) throw new Error(`private_email_${name}_required`);
  return value;
}

function fingerprint(value) {
  if (!value) return null;
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex').slice(0, 16)}`;
}

export function getPrivateEmailConfig(env = process.env) {
  const address = required(env.CYGNUS_EMAIL_ADDRESS, 'address');
  const password = required(env.CYGNUS_EMAIL_PASSWORD, 'password');
  const host = env.CYGNUS_EMAIL_HOST || DEFAULT_HOST;
  const imapPort = Number(env.CYGNUS_EMAIL_IMAP_PORT || DEFAULT_IMAP_PORT);
  const smtpPort = Number(env.CYGNUS_EMAIL_SMTP_PORT || DEFAULT_SMTP_PORT);

  if (!Number.isInteger(imapPort) || imapPort <= 0) throw new Error('private_email_invalid_imap_port');
  if (!Number.isInteger(smtpPort) || smtpPort <= 0) throw new Error('private_email_invalid_smtp_port');

  return {
    address,
    password,
    host,
    imap: { host, port: imapPort, secure: true, username: address },
    smtp: { host, port: smtpPort, secure: true, username: address },
  };
}

export function safePrivateEmailReceipt(config) {
  return {
    schema: 'nexo.private_email.connection.v1',
    address: config.address,
    host: config.host,
    imap: { port: config.imap.port, secure: config.imap.secure },
    smtp: { port: config.smtp.port, secure: config.smtp.secure },
    passwordFingerprint: fingerprint(config.password),
  };
}

export async function verifyPrivateEmailConnection(input = {}, deps = {}) {
  const config = input.config || getPrivateEmailConfig(input.env || process.env);
  const verifyImap = required(deps.verifyImap, 'verify_imap_adapter');
  const verifySmtp = required(deps.verifySmtp, 'verify_smtp_adapter');

  const [imap, smtp] = await Promise.all([
    verifyImap(config),
    verifySmtp(config),
  ]);

  return {
    ...safePrivateEmailReceipt(config),
    status: imap?.ok && smtp?.ok ? 'connected' : 'partial_or_failed',
    imapStatus: imap?.ok ? 'connected' : 'failed',
    smtpStatus: smtp?.ok ? 'connected' : 'failed',
    checkedAt: new Date().toISOString(),
  };
}

export async function sendPrivateEmail(message, deps = {}, env = process.env) {
  const config = getPrivateEmailConfig(env);
  const sendSmtp = required(deps.sendSmtp, 'send_smtp_adapter');
  const to = required(message?.to, 'to');
  const subject = required(message?.subject, 'subject');
  const text = message?.text ?? '';
  return sendSmtp({ config, from: config.address, to, subject, text });
}

export async function listPrivateEmailInbox(options = {}, deps = {}, env = process.env) {
  const config = getPrivateEmailConfig(env);
  const listImap = required(deps.listImap, 'list_imap_adapter');
  return listImap({ config, limit: Number(options.limit || 20) });
}

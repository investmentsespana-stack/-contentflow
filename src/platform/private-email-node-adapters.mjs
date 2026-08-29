import { ImapFlow } from 'imapflow';
import nodemailer from 'nodemailer';

function imapClient(config) {
  return new ImapFlow({
    host: config.imap.host,
    port: config.imap.port,
    secure: config.imap.secure,
    auth: {
      user: config.imap.username,
      pass: config.password,
    },
    logger: false,
  });
}

function smtpTransport(config) {
  return nodemailer.createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    secure: config.smtp.secure,
    auth: {
      user: config.smtp.username,
      pass: config.password,
    },
  });
}

export async function verifyImap(config) {
  const client = imapClient(config);
  try {
    await client.connect();
    return { ok: true };
  } finally {
    try {
      if (client.usable) await client.logout();
    } catch {
      // Best-effort cleanup only.
    }
  }
}

export async function verifySmtp(config) {
  const transport = smtpTransport(config);
  try {
    await transport.verify();
    return { ok: true };
  } finally {
    transport.close();
  }
}

export async function sendSmtp({ config, from, to, subject, text }) {
  const transport = smtpTransport(config);
  try {
    const result = await transport.sendMail({ from, to, subject, text });
    return {
      ok: true,
      messageId: result.messageId || null,
      accepted: result.accepted || [],
      rejected: result.rejected || [],
    };
  } finally {
    transport.close();
  }
}

export async function listImap({ config, limit = 20 }) {
  const client = imapClient(config);
  try {
    await client.connect();
    const lock = await client.getMailboxLock('INBOX');
    try {
      const exists = client.mailbox?.exists || 0;
      if (!exists) return [];
      const start = Math.max(1, exists - Math.max(1, limit) + 1);
      const messages = [];
      for await (const msg of client.fetch(`${start}:*`, {
        envelope: true,
        uid: true,
        flags: true,
        internalDate: true,
      })) {
        messages.push({
          uid: msg.uid,
          subject: msg.envelope?.subject || '',
          from: (msg.envelope?.from || []).map((x) => x.address).filter(Boolean),
          to: (msg.envelope?.to || []).map((x) => x.address).filter(Boolean),
          internalDate: msg.internalDate ? new Date(msg.internalDate).toISOString() : null,
          seen: msg.flags?.has('\\Seen') || false,
        });
      }
      return messages.slice(-limit).reverse();
    } finally {
      lock.release();
    }
  } finally {
    try {
      if (client.usable) await client.logout();
    } catch {
      // Best-effort cleanup only.
    }
  }
}

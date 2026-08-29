import { verifyPrivateEmailConnection } from '../src/platform/private-email-connector.mjs';
import { verifyImap, verifySmtp } from '../src/platform/private-email-node-adapters.mjs';

try {
  const receipt = await verifyPrivateEmailConnection({}, { verifyImap, verifySmtp });
  console.log(JSON.stringify(receipt, null, 2));
  if (receipt.status !== 'connected') process.exitCode = 2;
} catch (error) {
  console.error(JSON.stringify({
    schema: 'nexo.private_email.connection.v1',
    status: 'failed',
    error: error?.message || String(error),
  }, null, 2));
  process.exitCode = 1;
}

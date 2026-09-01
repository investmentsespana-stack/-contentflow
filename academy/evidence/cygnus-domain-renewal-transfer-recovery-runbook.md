# Cygnus Academy AI — Domain Renewal, Transfer & Recovery Runbook

Canonical institutional domain: `cygnusacademyai.com`
Registrar: Namecheap
Production host: `www.cygnusacademyai.com`
Platform: Vercel project `contentflow-ai`

## Current routing contract

- Apex `cygnusacademyai.com` redirects permanently to `www.cygnusacademyai.com`.
- `www.cygnusacademyai.com` is the production alias.
- DNS is managed at the registrar and must preserve the Vercel values shown by the live Vercel Domains configuration.
- Any DNS change must be verified in Vercel before being considered complete.

## Renewal

1. Keep registrar account ownership under Investments España LLC / authorized owner control.
2. Maintain account MFA and recovery methods.
3. Keep auto-renew enabled when an approved payment method is available.
4. Review renewal status at least 30 days before expiry.
5. After renewal, verify domain status, nameservers, DNS records, Vercel Valid Configuration, HTTPS and production routing.
6. Do not treat a renewal receipt alone as sufficient evidence; runtime HTTPS validation is required.

## Transfer

1. A transfer is a human-approved operation.
2. Confirm destination registrar, renewal implications and DNS continuity before unlocking the domain.
3. Preserve a snapshot of current DNS records and Vercel domain settings before transfer.
4. Obtain the registrar transfer authorization/EPP code only through the authenticated registrar account; never store it in source control.
5. Complete the transfer, restore/verify DNS, then validate apex redirect, `www` production routing and TLS.
6. Re-lock the domain after transfer when supported.

## Recovery

If the domain stops resolving or Vercel shows Invalid Configuration:

1. Confirm registrar domain status is ACTIVE and not expired/suspended.
2. Confirm authoritative nameservers and current DNS records at the registrar.
3. Compare the apex and `www` records against Vercel's live `View DNS configuration` values; Vercel's project-specific values are authoritative for this deployment.
4. Verify public DNS through multiple resolvers.
5. Verify Vercel shows Valid Configuration and production alias assignment.
6. Verify HTTPS on `https://www.cygnusacademyai.com/` and the apex redirect.
7. Relaunch Academy runtime checks for analytics, accessibility, error/loading and launch QA/SEO.
8. Record evidence and incident outcome in the Director/RARA control plane.

## Safety

- Do not publish registrar credentials, recovery codes, transfer codes or payment data in GitHub/Supabase task artifacts.
- Destructive DNS changes, registrar transfer, ownership changes and billing changes require human approval.
- Director/RARA may verify state, compare records, run safe probes and prepare corrections, but must escalate approval-gated operations.

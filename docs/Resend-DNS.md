# Resend DNS changes awaiting approval

Sending domain: `auth.kiwiapps.dev`.
Resend domain ID: `168a9601-1824-4a0e-a480-6ae6bfea1d73`.
Region: Ireland (`eu-west-1`). Receiving is disabled.

The following records were read from the domain's Resend dashboard. Names below are relative to Cloudflare's `kiwiapps.dev` zone. Use automatic TTL and DNS-only mode for CNAME records. Inspect for existing records before adding; do not replace unrelated records.

| Type | Name | Value |
| --- | --- | --- |
| TXT | `resend._domainkey.auth` | `p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDg4vk7BRiHP6pv/aNszAZDQg2bVyCT88tBYvO+dyy0bta+O+d9gfX6bgeKD2e+wzGRj9yb/ZTPfxeglLk105W/zXmPEQTQSoBg0tb0aVhgig8U+mICzYLbQ+6rzo0fsLBVKtqLrMAmpPSc4lcQy+WNUwXaQwyqzuD0zuzqiG64lQIDAQAB` |
| CNAME | `rsend.auth` | `rsend-euw1.forge.rmta.net` |
| CNAME | `send.auth` | `send.forge.rmta.net` |
| TXT | `_dmarc.auth` | `v=DMARC1; p=none;` |

The DKIM value is a public verification key, not an API credential. The scoped DMARC policy starts in monitoring mode. Neither root nor authentication-subdomain DMARC records were returned by the DNS lookup during preparation.

The API hostname `knowledge.kiwiapps.dev`, existing Shrimp records, nameservers, and root-domain mail routing are outside this change.

Resend setup instructions require one approval before DNS changes: [setup guide](https://resend.com/setup.md). No records in this plan have been applied yet.

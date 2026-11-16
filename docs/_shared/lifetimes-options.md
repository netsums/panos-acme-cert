| Option on `--issue` | Lifetime |
|---|---|
| *(none)* | Let's Encrypt default: 90 days, 64 from Feb 2027, 45 from Feb 2028 |
| `--cert-profile tlsserver` | 45 days now, to test the short lifetime before it's the default |

**Optional: renew a fixed number of days before expiry.** Add e.g.
`--days -15` to the `--issue` line to renew 15 days before the certificate
expires. Let's Encrypt can still ask for an earlier renewal when it needs to
(for example before revoking certificates). Most people should leave this out:
the default already renews with plenty of margin.

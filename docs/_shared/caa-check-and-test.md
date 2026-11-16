You should see your record, and no `letsencrypt.org` line without `accounturi`.
If your real zone is on Cloudflare with Universal SSL, Cloudflare can add CAA
records for its own CAs, including a bare `letsencrypt.org`. They don't show in
the dashboard, only in `dig`. If one is there, any Let's Encrypt account can
issue and the lock does nothing.

To test that the record blocks, issue once with a wrong `accounturi` in it.
Deactivate first, or Let's Encrypt reuses the earlier validation and skips the
CAA check:

```bash
acme.sh --deactivate -d "$CERT"
acme.sh --renew -d "$CERT" --force
```

That should fail with a CAA error. Put the right URL back, and the same two
commands should issue again. Each `--force` that succeeds is a real cert, so
mind the 5 duplicate certs per week.

- **Exact names only, not your apex.** A CAA record on `example.com` applies to
  every name below it that has no CAA record of its own, and would block the
  certs of your website and other services.
- **Add it after your staging tests.** The staging server uses a different
  account and would be refused.
- **A name that is a CNAME can't carry a CAA record.** Put it where the CNAME
  points, or leave that name out.
- **It covers a leaked token, not a taken-over box.** The box also holds your
  ACME account key. Keep it small and locked down.

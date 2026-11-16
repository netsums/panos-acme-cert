A CAA record tells every CA which CA, and which account, may issue for a name.
With it, a stolen burner token alone is useless: the thief's ACME account isn't
yours, so Let's Encrypt refuses.

Get your account URL (production, not staging):

```bash
grep ACCOUNT_URL ~/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf
```

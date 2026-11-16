```bash
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ +i:'
```

`0` is your certificate, `1` the Let's Encrypt intermediate (e.g. `YE2`), and
there may be a `2`. If you only see `0`, the intermediate is missing and some
clients will reject the certificate.

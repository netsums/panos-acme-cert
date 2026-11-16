<details>
<summary>Box doesn't trust your internal CA yet? (click)</summary>

From your admin account (`acmesh` has no sudo), with the root CA saved as PEM
in `corp-root-ca.crt`:

```bash
# Debian / Ubuntu
sudo cp corp-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# RHEL / Rocky / Alma
sudo cp corp-root-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
```

Don't use acme.sh's `--ca-bundle` instead. It *replaces* the trusted CAs for
all acme.sh traffic, so talking to Let's Encrypt breaks.

</details>

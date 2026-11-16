Each hook reads its own variables on the first deploy, see the acme.sh
[deploy hooks wiki](https://github.com/acmesh-official/acme.sh/wiki/deployhooks).
Bind once: select the cert in the decryption rule (PAN-OS 10.2 and later accept
several certs per rule). With `--always-force-new-domain-key`, firewall and
server get the new key together at every renewal.

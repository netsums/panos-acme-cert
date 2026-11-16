# Shared text for README.md and PANORAMA.md

Every `.md` file in this folder is a piece of text that appears word for word
in **both** guides. Edit it here, once. Don't edit that text in README.md or
PANORAMA.md: the copy there is overwritten.

In the guides, the shared text sits between two hidden markers. GitHub doesn't
display them, but you see them when you edit the file:

```
<!-- BEGIN shared/caa-intro.md: edit docs/_shared/caa-intro.md instead, this copy is overwritten -->
...
<!-- END shared/caa-intro.md -->
```

After a change here is pushed to `main`, the **Build docs** GitHub Action
copies it into both guides within about a minute and commits the result. To
do it by hand: `python3 scripts/build_docs.py`.

| File | Where it appears |
|---|---|
| `internal-ca-trust.md` | "Box doesn't trust your internal CA yet?" fold-out |
| `install-acmesh.md` | acme.sh install commands (README step 2, PANORAMA step 0c) |
| `caa-intro.md` | CAA: what it does, how to get your account URL |
| `caa-check-and-test.md` | CAA: checking, testing, and the four caveats |
| `ssl-inbound-hooks.md` | SSL Inbound Inspection: last paragraph (hooks wiki, binding) |
| `full-chain-check.md` | Full-chain check command and how to read it |
| `lifetimes-intro.md` | Shorter lifetimes: the CA/B Forum and Let's Encrypt dates |
| `lifetimes-options.md` | Shorter lifetimes: profile table and `--days` |

**Sharing more:** only text that is identical in both guides can be shared.
Wrap it in a BEGIN/END pair in both files, put the text into a new file
here, and run the script.

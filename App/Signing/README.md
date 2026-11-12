# Release signing certificate

Every Dustling release is signed with one self-signed certificate, `CN = Dustling Release Signing`. It is not an Apple certificate and macOS doesn't vouch for it (people still confirm the first open, see [INSTALL.md](../../docs/INSTALL.md)). It exists for one reason: **Full Disk Access survives updates.**

macOS stores Full Disk Access with the app's designated requirement. With an ad hoc signature that is the hash of that one build, so every update looks like a different app and loses the permission. Signed with this certificate it is

```
identifier "app.dustling.Dustling" and certificate leaf = H"<sha1>"
```

and every later build signed with the same certificate satisfies it.

## Files

| File | What it is |
| --- | --- |
| `release-certificate.pem` | The public certificate. Safe to publish. |
| `release-certificate.sha1` | Its SHA-1, one line. `scripts/build-dmg.sh` refuses to sign with any other certificate. |

The private key is never in this repository. It lives in `dustling-signing.p12` (kept by the maintainer, for example in a password manager) and in two GitHub Actions secrets, `DUSTLING_SIGNING_P12_BASE64` and `DUSTLING_SIGNING_P12_PASSWORD`, which the release workflow passes only to tag builds.

## Making the certificate (once)

```bash
DUSTLING_SIGNING_P12_PASSWORD='choose a long password' scripts/make-signing-certificate.sh ~/somewhere-outside-the-repo
```

It writes the two files above and prints the `gh secret set` commands that give the workflow the key. Commit the two files.

## Rotating

Only if the key leaks or the certificate expires (it is valid for 20 years). Run the script with `--rotate`, update the two secrets, commit the new files.

**Rotating costs every user one re-grant.** The requirement changes, so macOS no longer recognises Dustling, and after updating everyone must turn Full Disk Access off and on again for it (Dustling tells them when it isn't granted). Say so in that release's changelog. Don't rotate for any lesser reason.

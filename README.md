# HTL Quectel WebUI — signed releases

Binaries only. Source and documentation live in the private development repository.

Each release `vX.Y.Z` carries:

| File | What it is |
|---|---|
| `htlwebui.tar.gz` | the package `install.sh` installs on the card |
| `release.json` | tag, build id, channel, `sha256` and `size` of the package, notes |
| `release.json.sig` | ed25519 signature of `release.json` |
| `htlwebui-vX.Y.Z.htlpkg` | the three files above in one tar, for manual upload in the Web UI |

The fixed release `channels` holds `channels.json` (`seq`, `stable`, `beta`) and its signature.
Cards read it over plain github.com download links (never the API), refuse a `seq` lower than
the last one they saw, and install nothing whose signature does not verify.

## Verify a release yourself

Needs OpenSSL 3 (ed25519 with `-rawin`; macOS `/usr/bin/openssl` is LibreSSL and cannot).

```sh
openssl pkeyutl -verify -pubin -inkey release-ed25519.pub -rawin \
    -in release.json -sigfile release.json.sig
sha256sum htlwebui.tar.gz        # must equal "sha256" in release.json
```

`release-ed25519.pub` in this repository is the key the cards trust:

```
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAMf3M9uio1LWhWdn1D3+AfhciR643IMc3lgxSfOyUJAc=
-----END PUBLIC KEY-----
```

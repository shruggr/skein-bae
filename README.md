# skein-bae

Bae, the mail page for a [skein](https://github.com/shruggr/skein), as an app.
Version **0.1.0**. The page is a client. It does not yet take mail.

## What it is

One program, `bin/site.wasm`, function `get` (interface `bae.page/1`,
`writes: false`). It serves files from this app's own tree — the `tree`
link on the app record at `bae/app` — not from the `main` head. That is
why it is not skein-static: static only reads `main`, and an app does not
write `main`.

| request | answer |
|---|---|
| GET, HEAD of a file under `www/` | 200, content type by extension, the blob's CID as the ETag |
| `If-None-Match` with that ETag | 304 |
| a path ending in `/` | `index.html` |
| a directory named without its `/` | 301 |
| anything else | 404 or 405 |

Installed, the row is `/bae/` (prefix). The page is `www/index.html`.

## Use it

```
skein-host install <this-dir> --instance <handle>
```

The page is at `/bae/`.

## Build

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/site.wasm
zig build bin      # the same, into bin/site.wasm
zig build test
```

## Versions

| | |
|---|---|
| this app | 0.1.0 (tag `v0.1.0`) |
| skein-sdk | v0.4.0, by tag tarball and hash in `build.zig.zon` (`cbor`, `sk`; no wallet) |
| skein | log format 8 |

## Contributing

Work is tracked in shruggr/skein. MIT, as skein.

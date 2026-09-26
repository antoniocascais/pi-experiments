# Bill of materials — pi-experiments

Pins are edited in one place, the `Dockerfile`'s `ARG` lines, and nothing here is resolved at run
time. Pinning covers top-level versions and base image digests; transitive dependencies resolve at
build time.

## Image

| | |
| --- | --- |
| Tag | `pi-experiments:local` |
| Runs as | `agent`, uid/gid from `AGENT_UID`/`AGENT_GID` (default 1000) |

Image ID and size are intentionally not recorded here: this file is `COPY`ed into the image, so
writing an ID here would change the image and invalidate that same ID. Check `make status` instead.

## Base images (pinned by digest)

| Image | Used when | Digest |
| --- | --- | --- |
| `node:22-bookworm-slim` | always | `sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5` |
| `ghcr.io/astral-sh/uv:python3.13-bookworm-slim` | `WITH_PYTHON=1` | `sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca` |
| `golang:1.27.1-bookworm` | `WITH_GO=1` | `sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195` |
| `golangci/golangci-lint:v2.14.0` | `WITH_GO=1` | `sha256:ad862ba6b3798cbe0fd9fd7408d498fd74fbd2623a92406b2fd3898faf0bf98f` |

Bump one: `docker pull <image>:<tag>`, then
`docker image inspect <image>:<tag> --format '{{index .RepoDigests 0}}'`, paste the digest into
the matching `ARG` in the `Dockerfile`.

## Toolchain (verified by running the image)

| Component | Version | Notes |
| --- | --- | --- |
| pi | 0.85.1 | `@earendil-works/pi-coding-agent`, MIT, node >= 22.19.0 |
| pi-crew | 1.0.34 | `@melihmucuk/pi-crew`, MIT |
| node | 22.x | from the base image |
| git | 2.39.x | from the base image |
| python | 3.13.12 | via `uv python install`, only with `WITH_PYTHON=1` |
| uv | from the pinned uv image | only with `WITH_PYTHON=1` |
| go | 1.27.1 | only with `WITH_GO=1`; `GOTOOLCHAIN=local` blocks surprise downloads |
| golangci-lint | v2.14.0 | only with `WITH_GO=1` |
| trivy | operator-installed | host-side scanner, not in the image; `make scan`/`scan-fs` require it on PATH |

### Package integrity (npm registry)

```
@earendil-works/pi-coding-agent@0.85.1
  sha1     4cd00f653c3dabeb193b46f511044e7fbfe0f947
  sha512   FGRN+OHbWaefBPGaTggAdLjrIHW+s2PzLyglz/5dfLzb9of7uuXMXYC0fJIeZTw+shS32o2cuQ9jF7YSDuL/oQ==

@melihmucuk/pi-crew@1.0.34
  sha1     f90b7f90b3fb8d681b9647ac46382b392ba7b56d
  sha512   2q6Jv4xE8SBJgKnG+v7Br1qp0t0YLnijyBziUJwrouGC0xJEH3Vp9FUAm87HIkzQYvzHwCH/I59iQtscdgSJfw==
```

### pi-crew source audit (1.0.34)

Read in full at the published tarball -- the package declares no `repository`, so there is no git
tag to review instead.

- MIT, single maintainer, 31 files, 60 KB, 3,623 lines of TypeScript, unminified.
- Zero runtime dependencies; its `peerDependencies` are pi's own packages plus `typebox`, which pi
  provides through loader aliases and are never installed.
- No install scripts -- only `test` and `typecheck`.
- Grepped the full `extension/` tree for `child_process`, `execSync`, `spawnSync`, `eval`,
  `new Function`, `require(`, `fetch(`, any `http(s)://` literal, `net`/`dgram`, `process.env`,
  and every filesystem write call. No matches -- a pure in-process pi extension.

## Optional toolchains

Bare image by default (`WITH_GO=0 WITH_PYTHON=0`). `make build WITH_GO=1` and/or `WITH_PYTHON=1`
add the Go or Python toolchain as extra BuildKit stages -- each one is an opt-in addition to the
base image's fixable-CVE surface, so only turn one on if the target codebase actually needs it.

## Vulnerability gate

`make scan` runs `trivy image --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed
--exit-code 1` against the built image. Re-run it after every rebuild -- a green scan from an old
build means nothing once upstream packages pick up new CVEs.

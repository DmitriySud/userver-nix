# Note

> [!WARNING]
> This file and flake.nix are mostly AI-generated. Do not use it as an example of "how to do it"

# userver-nix

A thin Nix flake wrapper around the [userver](https://github.com/userver-framework/userver)
C++ framework (pinned to `v3.0`).

It fetches userver from GitHub and builds an installed, `find_package`-able
derivation. Feature flags select which drivers/libraries get built — each flag
toggles the matching `USERVER_FEATURE_*` cmake option, pulls in the right native
dependencies from nixpkgs, and exposes the corresponding `userver::<lib>` target.

## What's here

- `flake.nix` — the wrapper (fetch + feature-flagged build + dev shell)
- `README.md` — this file

## Requirements

Nix with flakes enabled:

```
experimental-features = nix-command flakes
```

## Quick use

Build the default (core + chaotic only):

```sh
nix build github:youruser/userver-nix#userver
```

Drop into a dev shell that puts userver on the cmake search path:

```sh
nix develop github:youruser/userver-nix
```

Inside the shell, `userver_DIR` is set, so a downstream project can do:

```cmake
find_package(userver REQUIRED COMPONENTS core postgresql grpc)
target_link_libraries(${PROJECT_NAME} PUBLIC userver::core userver::postgresql)
```

## Presets

| Attribute | Features enabled |
| --- | --- |
| `packages.userver` (default) | core, chaotic |
| `packages.userver-pg-grpc` | core, chaotic, postgresql, grpc, utest |
| `packages.userver-full` | all common drivers + easy + utest |

```sh
nix build .#userver-pg-grpc
```

## Custom feature sets

The flake exports `lib.mkUserver`, so you can compose your own build from
another flake:

```nix
{
  inputs.userver-nix.url = "github:youruser/userver-nix";

  outputs = { self, nixpkgs, userver-nix, ... }:
    let
      system = "x86_64-linux";
      userver = userver-nix.lib.mkUserver {
        # builds userver, defaults to system here
        features = {
          postgresql = true;
          redis      = true;
          grpc       = true;
          utest      = true;
        };
      };
    in { /* use `userver` as a buildInput / cmake dep */ };
}
```

Note: `mkUserver` is defined per-system inside `eachDefaultSystem`. If consuming
from outside, reference it through this flake's `lib` for the appropriate system,
or copy the builder into your own flake and pin `userver-src`.

## Available feature flags

These mirror userver's `USERVER_FEATURE_*` options. Default value in parentheses.

| Flag | Target | cmake option |
| --- | --- | --- |
| `core` (on) | `userver::core` | `USERVER_FEATURE_CORE` |
| `chaotic` (on) | `userver::chaotic` | `USERVER_FEATURE_CHAOTIC` |
| `utest` (off) | `userver::utest` | `USERVER_FEATURE_UTEST` |
| `testsuite` (off) | — (cmake helpers) | `USERVER_FEATURE_TESTSUITE` |
| `grpc` (off) | `userver::grpc` | `USERVER_FEATURE_GRPC` |
| `postgresql` (off) | `userver::postgresql` | `USERVER_FEATURE_POSTGRESQL` |
| `mongodb` (off) | `userver::mongo` | `USERVER_FEATURE_MONGODB` |
| `redis` (off) | `userver::redis` | `USERVER_FEATURE_REDIS` |
| `clickhouse` (off) | `userver::clickhouse` | `USERVER_FEATURE_CLICKHOUSE` |
| `kafka` (off) | `userver::kafka` | `USERVER_FEATURE_KAFKA` |
| `rabbitmq` (off) | `userver::rabbitmq` | `USERVER_FEATURE_RABBITMQ` |
| `mysql` (off) | `userver::mysql` | `USERVER_FEATURE_MYSQL` |
| `sqlite` (off) | `userver::sqlite` | `USERVER_FEATURE_SQLITE` |
| `odbc` (off) | `userver::odbc` | `USERVER_FEATURE_ODBC` |
| `otlp` (off) | `userver::otlp` | `USERVER_FEATURE_OTLP` |
| `easy` (off) | `userver::easy` | `USERVER_FEATURE_EASY` |

`userver::universal` and `userver::chaotic` are always built; `core` is on by
default. The `utest` flag additionally produces `userver::utest` / `userver::ubench`.

The `testsuite` flag toggles `USERVER_FEATURE_TESTSUITE`, which adds userver's
`UserverTestsuite.cmake` helpers (`userver_testsuite_add`,
`userver_testsuite_add_simple`, `userver_venv_setup`) for pytest-based
functional tests. It is **off by default**: when on, userver's cmake checks for
`python3-config` (python dev headers) at configure time and aborts if missing,
which is unnecessary weight for a plain build. The actual pytest/venv packages
are not installed by this wrapper — they're created per-service at build time by
`userver_testsuite_add*`. So enabling the flag here only provides `python3` and
the cmake functions; a service that runs functional tests still pulls its own
python deps. Leave it off unless you need those test targets.

## How it works

The build passes `USERVER_DOWNLOAD_PACKAGES=OFF` so userver uses the third-party
libraries provided by Nix (boost, fmt, grpc, libpq, etc.) instead of fetching
them via CPM at configure time — the Nix sandbox has no network access. Native
dependencies are added per-enabled-feature via the `featureDeps` map in
`flake.nix`. It builds with `USERVER_INSTALL=ON` in `Release` mode and installs a
cmake package config under `lib/cmake/userver`.

### chaotic codegen venv (no pip at build time)

`userver::chaotic` is always built as part of core. Its CMake
(`cmake/ChaoticGen.cmake` → `userver_venv_setup` in `cmake/UserverVenv.cmake`)
normally creates a Python venv and runs `pip install scripts/chaotic/requirements.txt`
at **configure** time. In the Nix sandbox that fails with a DNS/connection error
because there's no network.

`userver_venv_setup` has two properties the wrapper exploits: it only creates the
venv `if(NOT EXISTS <venv_dir>)`, and it only runs pip when the sentinel file
`<venv_dir>/venv-params.txt` is missing or doesn't match the requirements. So the
wrapper, in `preConfigure`:

1. Builds a Nix python (`pkgs.python3.withPackages` with `jsonschema`, `pyyaml`,
   `voluptuous`) — see `defaultChaoticPython`.
2. Pre-creates the expected venv (`build/chaotic/venv-userver-chaotic`) with
   `python -m venv --system-site-packages` against that python, so chaotic's deps
   resolve from the Nix store.
3. Writes a matching `venv-params.txt` sentinel.

cmake then finds an existing, valid venv and skips both `venv` creation and pip
entirely — the build stays fully offline. `USERVER_PYTHON_PATH` is also pointed at
the same python.

If your pinned userver needs a different chaotic requirement set, override it:

```nix
userver-nix.lib.mkUserver {
  features = { core = true; };
  chaoticPython = pkgs.python3.withPackages (ps: with ps; [
    jsonschema pyyaml voluptuous # + whatever scripts/chaotic/requirements.txt lists
  ]);
}
```

## Notes / caveats

- Pinned to userver `v3.0`. To bump, change the `userver-src` input ref and run
  `nix flake update userver-src`.
- The dependency lists in `featureDeps` cover the common case. Some drivers may
  need extra version-specific packages or `USERVER_PG_SERVER_INCLUDE_DIR`-style
  path hints depending on your nixpkgs; extend `cmakeFlags` / `featureDeps` if a
  configure step reports a missing package.
- `postgresql` enables userver's libpq portals patch by default
  (`USERVER_FEATURE_PATCH_LIBPQ`), which needs a static `libpq.a`. If that errors
  on your platform, add `-DUSERVER_FEATURE_PATCH_LIBPQ=OFF` to `cmakeFlags`.
- Linux only as written. macOS would need driver-list and dependency tweaks.

## License

The wrapper here is provided as-is. userver itself is Apache-2.0.

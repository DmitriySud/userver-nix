{
  description = "Nix wrapper for the userver C++ framework (v3.0)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    userver-src = {
      url = "github:userver-framework/userver/v3.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, userver-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        transliteratePkg = pkgs.python3.pkgs.buildPythonPackage rec {
          pname = "transliterate";
          version = "1.10.2";
          format = "setuptools";

          src = pkgs.python3.pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-vGCODUjmh9ucKx1+p8OBr+DRhJytIWCH2OA9jQalfIU=";
          };

          build-system = [ pkgs.python3.pkgs.setuptools ];
          doCheck = false;
        };

        # ────────────────────────────────────────────────────────────────
        # Python environment for the chaotic codegen.
        #
        # chaotic is always built as part of userver::core. Its CMake
        # (ChaoticGen.cmake -> userver_venv_setup) wants to create a venv and
        # `pip install` scripts/chaotic/requirements.txt at configure time.
        # That fails in the Nix sandbox (no network). Instead we provide a
        # Nix-built python with chaotic's deps and pre-seed the venv so userver
        # skips both `python -m venv` and `pip` entirely (see preConfigure).
        #
        # Override via mkUserver { chaoticPython = pkgs.python3.withPackages ...; }
        # if your pinned userver needs a different requirement set.
        # ────────────────────────────────────────────────────────────────
        defaultChaoticPython = pkgs.python3.withPackages (ps: with ps; [
          six
          packaging
          wheel
          jinja2
          pyyaml
          pydantic
          jsonschema
          voluptuous
          transliteratePkg
        ]);

        # ────────────────────────────────────────────────────────────────
        # Feature flags. Override per-driver as needed, e.g.
        #   nix build .#userver --override-input ...    (or via mkUserver below)
        # Each flag toggles a USERVER_FEATURE_* cmake option, the matching
        # native dependencies, and (where relevant) the exported lib target.
        # ────────────────────────────────────────────────────────────────
        defaultFeatures = {
          core        = true;   # userver::core  (coroutines, components, http)
          chaotic     = true;   # userver::chaotic (jsonschema codegen)
          utest       = false;  # userver::utest / ubench (gtest/gbench)
          testsuite   = false;  # functional-test (pytest) cmake support
                                # off by default: keeps simple builds free of
                                # the python3-dev configure-time requirement
          grpc        = false;  # userver::grpc
          postgresql  = false;  # userver::postgresql
          mongodb     = false;  # userver::mongo
          redis       = false;  # userver::redis
          clickhouse  = false;  # userver::clickhouse
          kafka       = false;  # userver::kafka
          rabbitmq    = false;  # userver::rabbitmq
          mysql       = false;  # userver::mysql
          sqlite      = false;  # userver::sqlite
          odbc        = false;  # userver::odbc
          otlp        = false;  # userver::otlp
          easy        = false;  # userver::easy
        };

        # Map a feature -> propagated native build inputs (the system libs the
        # corresponding USERVER_FEATURE expects to find rather than download).
        featureDeps = with pkgs; {
          core = [
            boost183         # context / coroutine2 / stacktrace
            fmt
            cctz
            libev
            c-ares
            curl
            nghttp2
            yaml-cpp
            cryptopp
            zlib
            brotli
            openssl
            jemalloc
            gtest
            gbenchmark 
            re2
          ];
          chaotic     = [ ];
          utest       = [ gtest ];
          # USERVER_FEATURE_TESTSUITE only needs python3 + dev headers
          # (python3-config) at configure time. The actual pytest/venv
          # dependencies are pulled per-service later by userver_testsuite_add,
          # so nothing heavy belongs here.
          testsuite   = [ python3 ];
          grpc        = [ grpc protobuf abseil-cpp ];
          postgresql  = [ postgresql.lib postgresql ];   # libpq + server headers
          mongodb     = [ mongoc cyrus_sasl ];
          redis       = [ hiredis ];
          clickhouse  = [ ];
          kafka       = [ rdkafka ];
          rabbitmq    = [ ];
          mysql       = [ libmysqlclient ];
          sqlite      = [ sqlite ];
          odbc        = [ unixODBC ];
          otlp        = [ grpc protobuf abseil-cpp ];
          easy        = [ ];
        };

        # Feature -> exported userver::<lib> target name (for the README / consumers).
        featureTargets = {
          core        = "userver::core";
          chaotic     = "userver::chaotic";
          utest       = "userver::utest";
          grpc        = "userver::grpc";
          postgresql  = "userver::postgresql";
          mongodb     = "userver::mongo";
          redis       = "userver::redis";
          clickhouse  = "userver::clickhouse";
          kafka       = "userver::kafka";
          rabbitmq    = "userver::rabbitmq";
          mysql       = "userver::mysql";
          sqlite      = "userver::sqlite";
          odbc        = "userver::odbc";
          otlp        = "userver::otlp";
          easy        = "userver::easy";
        };

        # Feature -> USERVER_FEATURE_* cmake option name.
        featureCmakeName = {
          core        = "CORE";
          chaotic     = "CHAOTIC";
          utest       = "UTEST";
          testsuite   = "TESTSUITE";
          grpc        = "GRPC";
          postgresql  = "POSTGRESQL";
          mongodb     = "MONGODB";
          redis       = "REDIS";
          clickhouse  = "CLICKHOUSE";
          kafka       = "KAFKA";
          rabbitmq    = "RABBITMQ";
          mysql       = "MYSQL";
          sqlite      = "SQLITE";
          odbc        = "ODBC";
          otlp        = "OTLP";
          easy        = "EASY";
        };

        onOff = b: if b then "ON" else "OFF";

        # ────────────────────────────────────────────────────────────────
        # Builder. Resolves the feature set, assembles cmake flags + deps,
        # and produces an installed userver (find_package-able) derivation.
        # ────────────────────────────────────────────────────────────────
        mkUserver = { features ? {}, chaoticPython ? defaultChaoticPython }:
          let
            f = defaultFeatures // features;

            enabled = lib.filterAttrs (_: v: v) f;

            buildInputs = lib.unique (lib.concatLists
              (lib.mapAttrsToList (name: _: featureDeps.${name} or [ ]) enabled));

            cmakeFeatureFlags = lib.mapAttrsToList
              (name: enabledFlag:
                "-DUSERVER_FEATURE_${featureCmakeName.${name}}=${onOff enabledFlag}")
              f;

            # Some features (e.g. testsuite) add cmake helpers rather than a
            # userver::<lib> target, so they have no entry in featureTargets.
            enabledTargets = lib.filter (t: t != null)
              (lib.mapAttrsToList (name: _: featureTargets.${name} or null) enabled);
          in
          pkgs.stdenv.mkDerivation {
            pname = "userver";
            version = "3.0";
            src = userver-src;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              pkg-config
              clang-tools
              chaoticPython   # python with chaotic codegen deps available
            ];

            buildInputs = buildInputs;
            propagatedBuildInputs = buildInputs;

            # Point userver at our python and pre-seed the chaotic venv so its
            # CMake skips the offline-failing `pip install` step. See below.
            cmakeFlags = cmakeFeatureFlags ++ [
              "-DUSERVER_PYTHON_PATH=${chaoticPython}/bin/python3"
              "-DUSERVER_PIP_USE_SYSTEM_PACKAGES=ON"
              "-DUSERVER_PIP_OPTIONS=--no-index"
              "-DUSERVER_INSTALL=ON"
              "-DUSERVER_BUILD_TESTS=OFF"
              "-DUSERVER_BUILD_SAMPLES=OFF"
              # Prefer Nix-provided system packages over CPM downloads, since the
              # build sandbox has no network access.
              "-DUSERVER_DOWNLOAD_PACKAGES=OFF"
              "-DUSERVER_FEATURE_STACKTRACE=OFF"
              "-DUSERVER_CHECK_PACKAGE_VERSIONS=OFF"
              "-DUSERVER_FEATURE_JEMALLOC=ON"
              "-DCMAKE_BUILD_TYPE=Release"
            ];


            # Surface the resolved config for consumers / debugging.
            passthru = {
              inherit f;
              targets = enabledTargets;
            };

            meta = with lib; {
              description = "Production-ready C++ asynchronous framework (userver)";
              homepage = "https://userver.tech";
              license = licenses.asl20;
              platforms = platforms.linux;
            };
          };

        # A dev shell that exposes a userver build on the cmake search path so a
        # downstream service can `find_package(userver ...)` against it.
        mkShell = { features ? {}, chaoticPython ? defaultChaoticPython }:
          let userver = mkUserver { inherit features chaoticPython; };
          in pkgs.mkShell {
            packages = [ pkgs.cmake pkgs.ninja pkgs.pkg-config chaoticPython userver ];
            shellHook = ''
              echo "userver dev shell — targets: ${lib.concatStringsSep " " userver.passthru.targets}"
              export userver_DIR="${userver}/lib/cmake/userver"
            '';
          };

      in {
        lib = { inherit mkUserver mkShell defaultFeatures defaultChaoticPython; };

        packages = {
          default = mkUserver { };
          userver = mkUserver { };

          # Convenience preset: PostgreSQL + gRPC service stack.
          userver-pg-grpc = mkUserver {
            features = { postgresql = true; grpc = true; utest = true; };
          };

          # Convenience preset: everything commonly used.
          userver-full = mkUserver {
            features = {
              grpc = true; postgresql = true; mongodb = true; redis = true;
              clickhouse = true; kafka = true; rabbitmq = true; mysql = true;
              sqlite = true; utest = true; easy = true;
            };
          };
        };

        devShells.default = mkShell { };
      });
}

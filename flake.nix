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
            boost                # context / coroutine2 / stacktrace
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
            concurrencpp
          ];
          chaotic     = [ ];
          utest       = [ gtest gbenchmark ];
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
        mkUserver = { features ? {} }:
          let
            f = defaultFeatures // features;

            enabled = lib.filterAttrs (_: v: v) f;

            buildInputs = lib.unique (lib.concatLists
              (lib.mapAttrsToList (name: _: featureDeps.${name} or [ ]) enabled));

            cmakeFeatureFlags = lib.mapAttrsToList
              (name: enabledFlag:
                "-DUSERVER_FEATURE_${featureCmakeName.${name}}=${onOff enabledFlag}")
              f;

            enabledTargets = lib.mapAttrsToList (name: _: featureTargets.${name}) enabled;
          in
          pkgs.stdenv.mkDerivation {
            pname = "userver";
            version = "3.0";
            src = userver-src;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              pkg-config
              python3
            ];

            buildInputs = buildInputs;

            cmakeFlags = cmakeFeatureFlags ++ [
              "-DUSERVER_INSTALL=ON"
              "-DUSERVER_BUILD_TESTS=OFF"
              "-DUSERVER_BUILD_SAMPLES=OFF"
              # Prefer Nix-provided system packages over CPM downloads, since the
              # build sandbox has no network access.
              "-DUSERVER_DOWNLOAD_PACKAGES=OFF"
              "-DUSERVER_CHECK_PACKAGE_VERSIONS=ON"
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
        mkShell = { features ? {} }:
          let userver = mkUserver { inherit features; };
          in pkgs.mkShell {
            packages = [ pkgs.cmake pkgs.ninja pkgs.pkg-config pkgs.python3 userver ];
            shellHook = ''
              echo "userver dev shell — targets: ${lib.concatStringsSep " " userver.passthru.targets}"
              export userver_DIR="${userver}/lib/cmake/userver"
            '';
          };

      in {
        lib = { inherit mkUserver mkShell defaultFeatures; };

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

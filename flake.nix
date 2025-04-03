{
  description = "A Nix-flake based Rust development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";

    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    { self, ... }@inputs:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import inputs.nixpkgs {
          localSystem = { inherit system; };
          overlays = [ (import inputs.rust-overlay) ];
        };

        # Target musl when building on 64-bit linux to create statically linked binaries
        # Set-up build dependencies and configure rust for statically lined binaries
        CARGO_BUILD_TARGET =
          {
            # Insert other "<host archs> = <target archs>" at will
            "x86_64-linux" = "x86_64-unknown-linux-musl";
          }
          .${system} or ((pkgs.stdenv.hostPlatform).rust.rustcTargetSpec);
        craneLib = (inputs.crane.mkLib pkgs).overrideToolchain (
          p:
          p.rust-bin.stable.latest.default.override {
            targets = [
              CARGO_BUILD_TARGET
              ((pkgs.stdenv.hostPlatform).rust.rustcTargetSpec)
            ];
          }
        );

        # Common vars
        inherit (craneLib.crateNameFromCargoToml { cargoToml = ./Cargo.toml; }) pname version;
        src = craneLib.cleanCargoSource (craneLib.path ./.);
        commonArgs = {
          inherit pname src CARGO_BUILD_TARGET;
          nativeBuildInputs = with pkgs; [ pkg-config ];
        };

        # Compile (and cache) cargo dependencies _only_
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Compile workspace code (including 3rd party dependencies)
        rust-project-cargo-deps-checker = craneLib.cargoAudit (
          commonArgs // { inherit (inputs) advisory-db; }
        );
        rust-project = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });
        tmux-thumbs = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            pname = "tmux-thumbs";
            doCheck = false;
          }
        );
        rust-project-clippy-check = craneLib.cargoClippy (
          commonArgs
          // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          }
        );
        rust-project-docs = craneLib.cargoDoc (commonArgs // { inherit cargoArtifacts; });
        rust-project-format-checker = craneLib.cargoFmt commonArgs;
        rust-project-tests = craneLib.cargoNextest (
          commonArgs
          // {
            # Consider setting `doCheck = false` on `rust-project` if you do not want
            # the tests to run twice
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          }
        );
        rust-project-coverage = craneLib.cargoLlvmCov (commonArgs // { inherit cargoArtifacts; });
        rust-project-sbom = craneLib.mkCargoDerivation (
          commonArgs
          // {
            # Require the caller to specify cargoArtifacts we can use
            inherit cargoArtifacts;

            # A suffix name used by the derivation, useful for logging
            pnameSuffix = "-sbom";

            # Set the cargo command we will use and pass through the flags
            installPhase = "mv bom.json $out";
            buildPhaseCargoCommand = "cargo cyclonedx -f json --all --override-filename bom";
            nativeBuildInputs = (commonArgs.nativeBuildInputs or [ ]) ++ [ pkgs.cargo-cyclonedx ];
          }
        );
      in
      {
        checks = {
          inherit
            rust-project
            rust-project-cargo-deps-checker
            # rust-project-coverage # TODO when understood how to pass `pkgs.llvm-tools`
            rust-project-docs
            rust-project-format-checker
            rust-project-sbom
            rust-project-tests
            tmux-thumbs

            # Run clippy (and deny all warnings) on the crate source,
            # again, resuing the dependency artifacts from above.
            #
            # Note that this is done as a separate derivation so that
            # we can block the CI if there are issues here, but not
            # prevent downstream consumers from building our crate by itself.
            # rust-project-clippy-check
            ;
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
          packages = with pkgs; [
            cargo-deny
            cargo-outdated
            cargo-watch
            cargo-tarpaulin

            # Editor stuffs
            lldb
            rust-analyzer
          ];

          inputsFrom = [
            rust-project
            rust-project-cargo-deps-checker
            rust-project-clippy-check
            # rust-project-coverage # see TODO
            rust-project-docs
            rust-project-format-checker
            rust-project-sbom
            rust-project-tests
          ];

          shellHook = ''
            cargo --version
            which hx && hx --health rust
            echo -e "\nRemember this useful utility:"
            echo -en "\t-->\tcargo --locked watch -cqw src/ -x "
            echo -e "'clippy -- -W clippy::pedantic -W clippy::nursery -W clippy::unwrap_used'\n"
          '';
        };

        packages = {
          # coverage = rust-project-coverage; # See TODO
          clippy-check = rust-project-clippy-check;
          default = rust-project;
          docs = rust-project-docs;
          docker = pkgs.dockerTools.buildImage {
            name = pname;
            tag = "v${version}";
            config = {
              Cmd = "--help";
              Entrypoint = [ "${rust-project}/bin/${pname}" ];
            };
          };
          ${pname} = rust-project;
          sbom = rust-project-sbom;
          tests = rust-project-tests;
          inherit tmux-thumbs;
        };

        # Now `nix fmt` works!
        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}

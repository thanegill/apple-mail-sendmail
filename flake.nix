{
  description = "sendmail-compatible CLI that hands messages to Apple Mail";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ { self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" ];

      perSystem = { config, self', pkgs, system, ... }:
        let
          # The pinned nixpkgs ships Tart 2.30.6, which predates macOS 27
          # guests (Cirrus Labs' golden-gate images), and `tart exec` before
          # 2.41.1 can drop or truncate large output (openai/tart#1347).
          tart = pkgs.tart.overrideAttrs (finalAttrs: previousAttrs: {
            version = "2.42.0";
            src = pkgs.fetchurl {
              url = "https://github.com/openai/tart/releases/download/${finalAttrs.version}/tart.tar.gz";
              hash = "sha256-qV3aIUtfZ2KYQw1mWoF0mS5rMA3SDGUzhbYEga6Bnd8=";
            };
            # Running tart.app during the build makes macOS 27 tag the bundle
            # (com.apple.macl), and Nix then fails to register the output.
            doInstallCheck = false;
            meta = previousAttrs.meta // { license = pkgs.lib.licenses.fsl11Asl20; };
          });

          # `withSendmailSymlink` controls whether $out/bin/sendmail is created
          # as a symlink to apple-mail-sendmail (drop-in compatibility). Default
          # true; pass false to install only the canonical binary name.
          makeSendmail = pkgs.lib.makeOverridable ({ withSendmailSymlink ? true }:
            pkgs.swiftPackages.stdenv.mkDerivation {
              pname = "apple-mail-sendmail";
              version = "0.1.0";
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = pkgs.lib.fileset.unions [
                  ./Package.swift
                  ./Sources
                ];
              };
              nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];

              installPhase = ''
                runHook preInstall
                install -Dm755 "$(swiftpmBinPath)/apple-mail-sendmail" "$out/bin/apple-mail-sendmail"
                ${pkgs.lib.optionalString withSendmailSymlink ''
                  ln -s apple-mail-sendmail "$out/bin/sendmail"
                ''}
                runHook postInstall
                '';

              # Tests use a recording AppleScript runner so they never drive Mail.app.
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                swift build -c release --product sendmail-test
                "$(swiftpmBinPath)/sendmail-test"
                runHook postCheck
              '';

              # Exercises main.swift's --help/--version handling, which the
              # in-process test runner cannot reach because it exits.
              doInstallCheck = true;
              nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
              versionCheckProgramArg = "--version";
              installCheckPhase = ''
                runHook preInstallCheck
                help_output="$("$out/bin/apple-mail-sendmail" --help < /dev/null)"
                grep -q '^USAGE: apple-mail-sendmail ' <<< "$help_output"
                runHook postInstallCheck
              '';

              meta = {
                description = "sendmail-compatible CLI that hands messages to Apple Mail";
                platforms = pkgs.lib.platforms.darwin;
                mainProgram = "apple-mail-sendmail";
              };
            });

          # The harness's own files, without its docs or the VM wrapper, so
          # editing tests/e2e/README.md, tests/e2e/CLAUDE.md or
          # tests/e2e/vm.sh does not change the harness's store path.
          e2eResources = pkgs.lib.fileset.toSource {
            root = ./tests/e2e;
            fileset = pkgs.lib.fileset.difference ./tests/e2e (pkgs.lib.fileset.unions [
              ./tests/e2e/README.md
              ./tests/e2e/CLAUDE.md
              ./tests/e2e/vm.sh
            ]);
          };

          # Live end-to-end harness. Building it only shellchecks the script;
          # running it drives Mail.app, so it is never part of checkPhase.
          e2eHarness = pkgs.writeShellApplication {
            name = "apple-mail-sendmail-e2e";
            runtimeInputs = [
              pkgs.mailpit
              pkgs.curl
              pkgs.jq
              pkgs.coreutils
              pkgs.gnused
              pkgs.gnugrep
              pkgs.gawk
              pkgs.diffutils
              pkgs.perl
              pkgs.socat
              pkgs.dnsutils
            ];
            runtimeEnv = {
              E2E_RESOURCES = "${e2eResources}";
              E2E_SENDMAIL = pkgs.lib.getExe self'.packages.default;
            };
            text = builtins.readFile ./tests/e2e/e2e.sh;
            meta.description = "Live end-to-end tests for apple-mail-sendmail against a local Mailpit";
          };

          # Runs e2eHarness inside a throwaway Tart clone of a prepared macOS
          # VM. Building it only shellchecks the script.
          e2eVm = pkgs.writeShellApplication {
            name = "apple-mail-sendmail-e2e-vm";
            runtimeInputs = [
              tart
              pkgs.openssh
              pkgs.jq
              pkgs.perl
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.gnutar
            ];
            runtimeEnv = {
              E2E_VM_HARNESS = e2eHarness;
              E2E_VM_HARNESS_EXE = pkgs.lib.getExe e2eHarness;
              E2E_VM_RESOURCES = "${e2eResources}";
              E2E_VM_NIX_INSTALLER = pkgs.fetchurl {
                url = "https://releases.nixos.org/nix/nix-2.35.6/install";
                hash = "sha256-b3vyBu+1TNSUH7J0kw28dP38FvywZ1fvJhyNfWnP1g4=";
              };
            };
            text = builtins.readFile ./tests/e2e/vm.sh;
            meta.description = "Run the apple-mail-sendmail live end-to-end tests in a disposable Tart macOS VM";
          };
        in {
          # Tart is source-available (FSL-1.1), so nixpkgs marks it unfree.
          # Allow that one package rather than setting allowUnfree.
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: inputs.nixpkgs.lib.getName pkg == "tart";
          };

          packages.default = makeSendmail { };
          packages.without-sendmail-symlink = makeSendmail { withSendmailSymlink = false; };
          packages.e2e = e2eHarness;
          packages.e2e-vm = e2eVm;

          # Building the harness shellchecks it; it never runs here.
          checks.e2e-shellcheck = e2eHarness;
          checks.e2e-vm-shellcheck = e2eVm;

          # The package's checkPhase runs the unit tests, so `nix flake check`
          # runs them by building it.
          checks.default = self'.packages.default;

          apps.default = {
            type = "app";
            program = "${self'.packages.default}/bin/apple-mail-sendmail";
          };

          apps.e2e = {
            type = "app";
            program = pkgs.lib.getExe e2eHarness;
            meta.description = "Live end-to-end tests for apple-mail-sendmail (drives Mail.app; see README)";
          };

          apps.e2e-vm = {
            type = "app";
            program = pkgs.lib.getExe e2eVm;
            meta.description = "Live end-to-end tests for apple-mail-sendmail in a disposable Tart macOS VM (see README)";
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.swift
              pkgs.swiftpm
              tart
            ];
          };

          formatter = pkgs.nixpkgs-fmt;
        };
    };
}

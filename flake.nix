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
              # The harness's own files, without its docs, so editing
              # tests/e2e/README.md or tests/e2e/CLAUDE.md does not change
              # this path.
              E2E_RESOURCES = "${pkgs.lib.fileset.toSource {
                root = ./tests/e2e;
                fileset = pkgs.lib.fileset.difference ./tests/e2e (pkgs.lib.fileset.unions [
                  ./tests/e2e/README.md
                  ./tests/e2e/CLAUDE.md
                ]);
              }}";
              E2E_SENDMAIL = pkgs.lib.getExe self'.packages.default;
            };
            text = builtins.readFile ./tests/e2e/e2e.sh;
            meta.description = "Live end-to-end tests for apple-mail-sendmail against a local Mailpit";
          };
        in {
          packages.default = makeSendmail { };
          packages.without-sendmail-symlink = makeSendmail { withSendmailSymlink = false; };
          packages.e2e = e2eHarness;

          # Building the harness shellchecks it; it never runs here.
          checks.e2e-shellcheck = e2eHarness;

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

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.swift
              pkgs.swiftpm
            ];
          };

          formatter = pkgs.nixpkgs-fmt;
        };
    };
}

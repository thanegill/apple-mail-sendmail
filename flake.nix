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
          versionFile = ./Sources/SendmailCore/Version.swift;
          versionMatch = builtins.match
            ''.*public static let string = "([0-9]+[.][0-9]+[.][0-9]+)".*''
            (builtins.readFile versionFile);
          version =
            if versionMatch == null
            then throw "flake.nix: ${toString versionFile} has no `public static let string = \"X.Y.Z\"` line to read the version from"
            else builtins.head versionMatch;

          # The pinned nixpkgs ships Tart 2.37.0, which predates macOS 27
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

          # Third-party messages for tests/conformance/differential.py, fetched
          # instead of vendored. CPython's test_email messages come from the
          # source of the same Python the check compares against, so they move
          # with nixpkgs; mail-parser's are pinned by `rev` and `hash`.
          mailParserSrc = pkgs.fetchFromGitHub {
            owner = "stalwartlabs";
            repo = "mail-parser";
            rev = "8e149db324542e1023026fe50959a25864efff48";
            sparseCheckout = [ "resources/eml" ];
            hash = "sha256-F9L+XztcupNhe5DAzehgHEf5V6VDhEAcSjgBqmmRcNY=";
          };
          conformanceCorpus = pkgs.runCommand "apple-mail-sendmail-conformance-corpus" { } ''
            mkdir -p "$out/cpython" "$out/mail-parser"
            tar -xJf ${pkgs.python3.src} -C "$out/cpython" --strip-components=5 \
              --wildcards '*/Lib/test/test_email/data/msg_*.txt'
            for message in ${mailParserSrc}/resources/eml/rfc/*.eml; do
              cp "$message" "$out/mail-parser/rfc-$(basename "$message")"
            done
            for message in ${mailParserSrc}/resources/eml/issues/98-*.eml; do
              cp "$message" "$out/mail-parser/issue-$(basename "$message")"
            done
          '';

          # `withSendmailSymlink` controls whether $out/bin/sendmail is created
          # as a symlink to apple-mail-sendmail (drop-in compatibility). Default
          # true; pass false to install only the canonical binary name.
          makeSendmail = pkgs.lib.makeOverridable ({ withSendmailSymlink ? true }:
            pkgs.swiftPackages.stdenv.mkDerivation {
              pname = "apple-mail-sendmail";
              inherit version;
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = pkgs.lib.fileset.unions [
                  ./Package.swift
                  ./Sources
                  ./tests/conformance
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
              # The differential check compares SendmailCore's MIME parse of
              # tests/conformance/corpus and the fetched corpus with CPython's
              # email package.
              doCheck = true;
              nativeCheckInputs = [ pkgs.python3 ];
              checkPhase = ''
                runHook preCheck
                swift build -c release --product sendmail-test
                "$(swiftpmBinPath)/sendmail-test"
                python3 -I tests/conformance/differential.py --dump "$(swiftpmBinPath)/sendmail-test" \
                  --corpus tests/conformance/corpus --corpus ${conformanceCorpus}
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
                license = pkgs.lib.licenses.mit;
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

          # git pushes over the system ssh on PATH: nixpkgs' openssh rejects
          # macOS-only ssh_config options such as UseKeychain.
          releaseScript = pkgs.writeShellApplication {
            name = "apple-mail-sendmail-release";
            runtimeInputs = [
              pkgs.git
              pkgs.gh
              pkgs.nix
              pkgs.coreutils
              pkgs.gnused
              pkgs.gnugrep
            ];
            text = builtins.readFile ./scripts/release.sh;
            meta.description = "Open an apple-mail-sendmail release PR, or tag and publish a merged one";
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
          packages.release = releaseScript;
          packages.conformance-corpus = conformanceCorpus;

          # Building these shellchecks them; they never run here.
          checks.e2e-shellcheck = e2eHarness;
          checks.e2e-vm-shellcheck = e2eVm;
          checks.release-shellcheck = releaseScript;

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

          apps.release = {
            type = "app";
            program = pkgs.lib.getExe releaseScript;
            meta.description = "Release tooling: nix run .#release -- prepare|tag X.Y.Z [--dry-run] (see RELEASING.md)";
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.swift
              pkgs.swiftpm
              pkgs.python3
              tart
            ];
          };

          formatter = pkgs.nixpkgs-fmt;
        };
    };
}

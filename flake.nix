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
              src = ./.;
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
        in {
          packages.default = makeSendmail { };
          packages.without-sendmail-symlink = makeSendmail { withSendmailSymlink = false; };

          apps.default = {
            type = "app";
            program = "${self'.packages.default}/bin/apple-mail-sendmail";
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

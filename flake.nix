{
  description = "Full-stack Dart/Flutter dev environment (Client / Hub / Node)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nur.url = "github:p3psi-boo/nur";
  };

  outputs = { self, nixpkgs, nur }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          src = pkgs.lib.cleanSource ./.;
        in
        {
          hub = pkgs.buildDartApplication {
            pname = "hub";
            version = "0.1.0";
            inherit src;
            sourceRoot = "source/hub";
            autoPubspecLock = ./hub/pubspec.lock;
          };
          daemon = pkgs.buildDartApplication {
            pname = "daemon";
            version = "0.1.0";
            inherit src;
            sourceRoot = "source/node";
            autoPubspecLock = ./node/pubspec.lock;
          };
          default = pkgs.buildDartApplication {
            pname = "daemon";
            version = "0.1.0";
            inherit src;
            sourceRoot = "source/node";
            autoPubspecLock = ./node/pubspec.lock;
          };
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          linuxNativeDeps = with pkgs; lib.optionals stdenv.isLinux [
            gcc
            glibc.dev
            linuxHeaders
          ];

          darwinNativeDeps = with pkgs; lib.optionals stdenv.isDarwin [
            cocoapods
          ];
        in
        {
          default = pkgs.mkShell {
            name = "dart-flutter-devshell";

            packages = (with pkgs; [
              # ── Dart & Flutter SDKs ─────────────────────────
              dart
              flutter
              jdk17
              android-tools

              # ── Base utilities ──────────────────────────────
              git
              wget
              curl
              just
              gnumake
              jq
              which

              # ── Linux native build toolchain ────────────────
              pkg-config
              clang
              cmake
              ninja
              gtk3
              glib
              pcre2
            ] ++ linuxNativeDeps ++ darwinNativeDeps)
            ++ [ nur.packages.${system}.fdb ];

            shellHook = ''
              # ── Environment Variables ───────────────────────
              export FLUTTER_ROOT="${pkgs.flutter}"
              export DART_SDK="${pkgs.dart}"
              export JAVA_HOME="${pkgs.jdk17.home}"
              export PUB_CACHE="$PWD/.dart_tool/.pub-cache"
              export PATH="$JAVA_HOME/bin:$PUB_CACHE/bin:$PATH"

              # ── Version probes ────────────────────────────
              DART_VER=$(dart --version 2>&1 | head -n1 || echo "N/A")
              FLUTTER_VER=$(flutter --version 2>&1 | head -n1 || echo "N/A")
              JAVA_VER=$(java -version 2>&1 | head -n1 || echo "N/A")

              # ── Pretty print helpers ──────────────────────
              CYAN="\033[0;36m"
              GREEN="\033[0;32m"
              YELLOW="\033[1;33m"
              BLUE="\033[0;34m"
              BOLD="\033[1m"
              DIM="\033[2m"
              RESET="\033[0m"

              # ── Welcome banner ──────────────────────────────
              echo ""
              echo -e "$CYAN╔════════════════════════════════════════════════════════════════════╗$RESET"
              echo -e "$CYAN║$RESET   $BOLD🚀  Dart / Flutter  Full-Stack Dev Environment$RESET                    $CYAN║$RESET"
              echo -e "$CYAN╠════════════════════════════════════════════════════════════════════╣$RESET"
              echo -e "$CYAN║$RESET   $DIM SYSTEM  $RESET $GREEN${system}$RESET                                          $CYAN║$RESET"
              echo -e "$CYAN║$RESET   $DIM NIXPKGS $RESET $GREEN${pkgs.lib.version}$RESET                                          $CYAN║$RESET"
              echo -e "$CYAN╠════════════════════════════════════════════════════════════════════╣$RESET"
              echo -e "$CYAN║$RESET   $YELLOW➜$RESET Dart:    $DART_VER                              $CYAN║$RESET"
              echo -e "$CYAN║$RESET   $YELLOW➜$RESET Flutter: $FLUTTER_VER                           $CYAN║$RESET"
              echo -e "$CYAN║$RESET   $YELLOW➜$RESET Java:    $JAVA_VER                              $CYAN║$RESET"
              echo -e "$CYAN╠════════════════════════════════════════════════════════════════════╣$RESET"
              echo -e "$CYAN║$RESET   Available: dart, flutter, java, adb, fdb, just, git, curl, wget, make, cmake, ninja   $CYAN║$RESET"
              echo -e "$CYAN║$RESET   FLUTTER_ROOT → $BLUE$FLUTTER_ROOT$RESET              $CYAN║$RESET"
              echo -e "$CYAN║$RESET   JAVA_HOME    → $BLUE$JAVA_HOME$RESET              $CYAN║$RESET"
              echo -e "$CYAN╚════════════════════════════════════════════════════════════════════╝$RESET"
              echo ""

              # ── Direnv-friendly hint ────────────────────────
              if [ -n "$DIRENV_DIR" ]; then
                echo -e "$DIM💡  Direnv active — environment auto-loaded on cd.$RESET"
                echo ""
              fi
            '';
          };
        }
      );
    };
}

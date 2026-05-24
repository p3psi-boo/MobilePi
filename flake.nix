{
  description = "Full-stack Dart/Flutter dev environment (Client / Hub / Node)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
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

            packages = with pkgs; [
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
            ] ++ linuxNativeDeps ++ darwinNativeDeps;

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
              echo -e "$CYAN║$RESET   Available: dart, flutter, java, adb, just, git, curl, wget, make, cmake, ninja   $CYAN║$RESET"
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

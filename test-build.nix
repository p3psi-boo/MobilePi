{ pkgs ? import <nixpkgs> {} }:
pkgs.buildDartApplication {
  pname = "hub";
  version = "0.1.0";
  src = pkgs.lib.cleanSource ./.;
  sourceRoot = "source/hub";
  autoPubspecLock = ./hub/pubspec.lock;
}

{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = [
    pkgs.zig_0_16
    pkgs.zls_0_16
    pkgs.git
    pkgs.nasm
    pkgs.pkg-config
    pkgs.raylib

    pkgs.libGL
    # X11 dependencies
    pkgs.libx11
    pkgs.libx11.dev
    pkgs.libxcursor
    pkgs.libxi
    pkgs.libxinerama
    pkgs.libxrandr
  ];
}

{ pkgs, ... }:

{
  # Zig 0.17.x toolchain — matches build.zig.zon and the CI workflows.
  packages = [
    pkgs.zig_0_17
  ];

  # Convenience wrappers. Named to avoid shadowing the `test`/`build` shell builtins.
  scripts.zb.exec = "zig build \"$@\"";
  scripts.zt.exec = "zig build test --summary all \"$@\"";

  enterShell = ''
    echo "hparse dev shell — zig $(zig version)"
    echo "  zb  → zig build"
    echo "  zt  → zig build test --summary all"
  '';

  # `devenv test` builds and runs the unit tests.
  enterTest = ''
    zig build test --summary all
  '';
}

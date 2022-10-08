id: bpm1mv3scb9cdf9ir1ksp9fx92wg55511p6pfzjj5vxoc6gk
name: obsidian2web
license: MIT
description: An HTML renderer for Obsidian vaults
root_dependencies:
  - name: libpcre
    main: src/main.zig
    src: git https://github.com/kivikakk/libpcre.zig
  - src: git https://github.com/kivikakk/koino
    name: koino
    main: src/koino.zig
    dependencies:
      - src: git https://github.com/kivikakk/libpcre.zig
      - src: git https://github.com/kivikakk/htmlentities.zig
      - src: git https://github.com/kivikakk/zunicode

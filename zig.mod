id: bpm1mv3scb9cdf9ir1ksp9fx92wg55511p6pfzjj5vxoc6gk
name: obsidian2web
license: MIT
description: An HTML renderer for Obsidian vaults
dev_dependencies:
  - name: funnier-libpcre
    main: src/main.zig
    src: git https://github.com/lun-4/libpcre.zig
  - src: git https://github.com/lun-4/koino
    name: koino
    main: src/koino.zig
    version: branch-add-zigmod-support

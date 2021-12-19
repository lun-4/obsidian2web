id: bpm1mv3scb9cdf9ir1ksp9fx92wg55511p6pfzjj5vxoc6gk
name: obsidian2web
license: Proprietary
description: An HTML renderer for Obsidian vaults
dev_dependencies:
  - src: system_lib pcre
  - name: libpcre
    main: src/main.zig
    src: git https://github.com/lun-4/libpcre.zig
  - src: git https://github.com/kivikakk/koino
    name: koino
    main: src/koino.zig
    dependencies:
      - name: libpcre
        main: .zigmod/deps/git/github.com/kivikakk/koino/vendor/libpcre.zig/src/main.zig
        src: local libpcre
      - name: htmlentities
        main: .zigmod/deps/git/github.com/kivikakk/koino/vendor/htmlentities.zig/src/main.zig
        src: local htmlentities
      - name: clap
        main: .zigmod/deps/git/github.com/kivikakk/koino/vendor/zig-clap/clap.zig
        src: local clap
      - name: zunicode
        main: .zigmod/deps/git/github.com/kivikakk/koino/vendor/zunicode/src/zunicode.zig
        src: local zunicode

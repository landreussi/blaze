{
  description = "blaze: check, run and test Rust workspaces, compiled by blaze itself (no rustc)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        # The one toolchain blaze is pinned to: the dated nightly in pins/toolchain
        # (`nightly-YYYY-MM-DD`, moved by harness/toolchain_bump.py, which also moves the
        # rust-overlay input to one that has it). rust-src is for rust-analyzer in an editor of
        # this repository; blaze reads none of it (its standard library is library/,
        # docs/toolchain.md).
        pin = pkgs.lib.removePrefix "nightly-" (pkgs.lib.fileContents ./pins/toolchain);
        rust = pkgs.rust-bin.nightly.${pin}.default.override {
          extensions = [ "rust-src" ];
        };
        # The same nightly with rustc_codegen_cranelift, for the setups bench.py compares with
        # (`--setups`, docs/benchmarks.md).
        nightly = pkgs.rust-bin.nightly.${pin}.default.override {
          extensions = [ "rustc-codegen-cranelift-preview" ];
        };
        # The one LLVM the `llvm` feature builds against, for every build of it: the dev shells
        # here, CI (`.#llvm`, .github/actions/toolchain) and the release.
        # pins/llvm.json pins it: LLVM 23.1.4, built for each target by
        # .github/scripts/llvm.py (the llvm workflow) and fetched here by its sha256. Its static libraries, headers, llvm-config,
        # llvm-dwarfdump and llvm-pdbutil; LLVM_SYS_231_PREFIX names it, and
        # vendor/llvm-sys links it statically, and its build script (pin.rs) refuses any other. Its tools were
        # built on Ubuntu 22.04 with the C++ runtime linked in: on Linux they are pointed at the
        # store's libc.
        llvmPin = builtins.fromJSON (builtins.readFile ./pins/llvm.json);
        llvm =
          let pin = llvmPin.targets.${triple} or (throw "pins/llvm.json has no LLVM for ${triple}: run the llvm workflow");
          in pkgs.stdenv.mkDerivation {
            pname = "blaze-llvm";
            inherit (llvmPin) version;
            src = pkgs.fetchurl { url = "${llvmPin.release}/${pin.name}"; inherit (pin) sha256; };
            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
            buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
            dontConfigure = true;
            dontBuild = true;
            # The archives are what the release links: not stripped or rewritten.
            dontStrip = true;
            installPhase = "cp -r . $out";
          };
        # blaze lays out the same archive itself and sets this for llvm-sys's and blaze-stencil's
        # build scripts over the shell's value (Cargo.toml's [workspace.metadata.blaze.native.llvm]);
        # the shell's serves a stage 0 older than that table, and tools other than blaze.
        llvmEnv = { LLVM_SYS_231_PREFIX = "${llvm}"; };
        # The Python workspace uses Nix's pinned interpreter on NixOS, where uv's downloaded
        # interpreters cannot run. uv itself comes from the same flake.lock as the toolchain.
        scripts = {
          packages = [ pkgs.uv pkgs.python313 pkgs.nodejs ];
          UV_PYTHON = "${pkgs.python313}/bin/python3";
          UV_PYTHON_DOWNLOADS = "never";
        };
        # What harness/bench.py runs in on the benchmark machine (docs/benchmarks.md): the
        # pinned toolchain, the LLVM 23 blaze links, and the C side the projects' build
        # scripts use. Nothing here wraps rustc (no sccache) or replaces the default linker:
        # mold and wild are on PATH for the setups that ask for them with `-fuse-ld`. Every
        # library directory here costs every link a `realpath` in Nix's linker wrapper, which
        # cargo pays and blaze does not: what only one project needs goes in a shell of its own.
        bench = llvmEnv // {
          packages = [
            rust
            pkgs.python313
            pkgs.uv
            pkgs.nodejs
            pkgs.git
            pkgs.pkg-config
            pkgs.openssl
            llvm
            pkgs.libffi
            pkgs.libxml2
            pkgs.zlib
            pkgs.ncurses
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            # bevy's audio, input and windowing crates link these.
            pkgs.alsa-lib
            pkgs.udev
            pkgs.wayland
            pkgs.libxkbcommon
            pkgs.mold
            pkgs.wild
          ] ++ [
            # dx (Dioxus hot-patching): harness/hotpatch.py, which used it, is deleted; it goes with the flake.
            pkgs.dioxus-cli
          ];
          BLAZE_NIGHTLY = "${nightly}";
          inherit (scripts) UV_PYTHON UV_PYTHON_DOWNLOADS;
          # A C compiler as a distribution ships it: the wrapper's _FORTIFY_SOURCE warns at the
          # -O0 of a debug build, which fails configure probes (jemalloc's, in fd).
          hardeningDisable = [ "all" ];
        };
        # This system's Rust target triple, which names its archives in pins/llvm.json and in a
        # release.
        triple = {
          x86_64-linux = "x86_64-unknown-linux-gnu";
          aarch64-linux = "aarch64-unknown-linux-gnu";
          aarch64-darwin = "aarch64-apple-darwin";
        }.${system};
        # What `nix profile add github:indexable-inc/blaze` installs: the release
        # .github/blaze-cli-version names (the stage 0 release.yaml builds a release with), its
        # archive for this system from blaze's R2 bucket, as site/install.sh downloads it
        # (docs/release.md, "Where the bytes are"), checked by the sha256 the release's SHA256SUMS
        # gives it. tools/nix/SHA256SUMS is that release's SHA256SUMS, byte for byte, so a change
        # of the version replaces it in the same commit:
        #
        #   curl -fsSL -o tools/nix/SHA256SUMS "https://blaze-releases.ix.dev/v$(cat .github/blaze-cli-version)/SHA256SUMS"
        #
        # A release is the binary blaze exported of itself (release.yaml). Nix builds no blaze of
        # this tree: only blaze builds blaze, and its export fetches the toolchain and the crates,
        # for which the Nix sandbox has no network (#2443). On Linux the binary's interpreter and
        # libgcc_s are pointed into the store, so it runs on NixOS too; nothing else is rewritten.
        release =
          let
            version = pkgs.lib.fileContents ./.github/blaze-cli-version;
            name = "blaze-v${version}-${triple}";
            sum = text:
              let found = builtins.match "([0-9a-f]{64})  ([^ ]+)" text;
              in if found == null
                then throw "tools/nix/SHA256SUMS: `${text}` is not a line of a SHA256SUMS (a sha256, two spaces, a name)"
                else { name = builtins.elemAt found 1; value = builtins.elemAt found 0; };
            sums = builtins.listToAttrs (map sum (builtins.filter (text: text != "")
              (pkgs.lib.splitString "\n" (builtins.readFile ./tools/nix/SHA256SUMS))));
          in pkgs.stdenv.mkDerivation {
            pname = "blaze";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://blaze-releases.ix.dev/v${version}/${name}.tar.xz";
              sha256 = sums."${name}.tar.xz" or (throw ("tools/nix/SHA256SUMS has no ${name}.tar.xz, so it is "
                + "not the SHA256SUMS of ${version}, the release .github/blaze-cli-version names: copy "
                + "https://blaze-releases.ix.dev/v${version}/SHA256SUMS over it"));
            };
            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
            buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 blaze $out/bin/blaze
              runHook postInstall
            '';
            # The check release.yaml makes of each archive it ships: the binary starts and names
            # its version.
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              $out/bin/blaze --version | grep -F ${version}
              runHook postInstallCheck
            '';
            meta = {
              description = "blaze, as its release ships it";
              homepage = "https://ix.dev/blaze";
              license = with pkgs.lib.licenses; [ mit asl20 ];
              sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
              mainProgram = "blaze";
            };
          };
        # `nix run .#duckdb`: the DuckDB `blaze debug sql`, `blaze explain` and the explorer run,
        # nixpkgs' at the locked rev, parquet built in, so nothing downloads. Pinned: a nixpkgs
        # bump that changes it stops here, a visible change.
        duckdb =
          assert pkgs.duckdb.version == "1.5.5";
          pkgs.duckdb;
      in {
        packages = {
          # `nix profile add github:indexable-inc/blaze`, and `nix run github:indexable-inc/blaze`
          # (its `meta.mainProgram`): the pinned release. `#blaze` names it too.
          default = release;
          blaze = release;
          inherit duckdb;
          # The pinned LLVM: its tools (llvm-dwarfdump), which CI puts on PATH where the harnesses
          # read debug info, and the prefix a build of the `llvm` feature links.
          inherit llvm;
        };
        apps.duckdb = {
          type = "app";
          program = "${duckdb}/bin/duckdb";
        };
        # `nix develop`: the pinned LLVM (LLVM_SYS_231_PREFIX, its tools on PATH) and a C
        # toolchain with libstdc++.a, so `cargo build -p blaze-engine` links it in. Rust is
        # rustup at the pinned nightly: plain `cargo` is pins/toolchain's and `cargo +<toolchain>` works.
        devShells.default = pkgs.mkShell (llvmEnv // {
          packages = scripts.packages ++ [ pkgs.rustup llvm ];
          inherit (scripts) UV_PYTHON UV_PYTHON_DOWNLOADS;
          RUSTUP_TOOLCHAIN = pkgs.lib.fileContents ./pins/toolchain;
          # The pinned DuckDB that `blaze slow`, `blaze debug sql` and `blaze explain` run (blaze
          # never looks for one on PATH).
          BLAZE_DUCKDB = "${duckdb}/bin/duckdb";
          # As in the bench shell: the wrapper's _FORTIFY_SOURCE fails configure probes at -O0 in
          # the C code of the projects the harnesses build.
          hardeningDisable = [ "all" ];
        } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # rustup's rustc links x86-64 Linux with its own rust-lld, past the wrapper of the
          # shell's linker that writes the store's libraries into the binary's RUNPATH: without
          # this the binary finds neither the store's glibc nor its libgcc_s when it runs.
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-Clinker-features=-lld";
        });
        # What builds, runs and inspects wasm32 programs: wasmtime for wasm32-wasip1 and
        # `--invoke` of a library's exports,
        # wasm-tools where the harnesses read objects, wasm-bindgen and node for web guests. The
        # targets are rustup's: `rustup target add wasm32-wasip1 wasm32-unknown-unknown`.
        devShells.wasm = pkgs.mkShell (llvmEnv // {
          packages = scripts.packages ++ [ pkgs.rustup llvm pkgs.wasmtime pkgs.wasm-tools pkgs.wasm-bindgen-cli ];
          inherit (scripts) UV_PYTHON UV_PYTHON_DOWNLOADS;
          RUSTUP_TOOLCHAIN = pkgs.lib.fileContents ./pins/toolchain;
          hardeningDisable = [ "all" ];
        });
        devShells.bench = pkgs.mkShell bench;
        # Python-only work needs neither LLVM nor a Rust toolchain.
        devShells.scripts = pkgs.mkShell scripts;
        # What harness/bench.py measures bun in (bunprep.py, fed1eb428d:docs/research/bun.md):
        # bun's own pinned nightly in place of blaze's, for the cargo side (blaze ignores the pin
        # and compiles its own library/), with rust-src, which bun's own build of its Rust
        # (`-Zbuild-std`, run by bunprep.py's plan step) reads std from, and
        # what bun's own build of its C and C++ needs, as its flake.nix has it: LLVM 23 as the
        # C and C++ compiler, cmake, ninja, nasm (x86), go, a bun to run its build scripts, and on Linux lld.
        # blaze itself is built in the bench shell.
        devShells.bench-bun = (pkgs.mkShell.override { stdenv = pkgs.llvmPackages_23.stdenv; }) {
          packages = [
            (pkgs.rust-bin.nightly."2026-09-15".default.override { extensions = [ "rust-src" ]; })
            pkgs.python313
            pkgs.uv
            pkgs.nodejs
            pkgs.git
            pkgs.curl
            pkgs.unzip
            pkgs.xz
            pkgs.pkg-config
            pkgs.cmake
            pkgs.ninja
            pkgs.nasm
            pkgs.go
            pkgs.bun
            pkgs.perl
            pkgs.ruby
            pkgs.libtool
            pkgs.llvmPackages_23.clang
            pkgs.llvmPackages_23.llvm
            pkgs.llvmPackages_23.lld
          ];
          hardeningDisable = [ "all" ];
          inherit (scripts) UV_PYTHON UV_PYTHON_DOWNLOADS;
          shellHook = ''
            export CC=${pkgs.llvmPackages_23.clang}/bin/clang CXX=${pkgs.llvmPackages_23.clang}/bin/clang++
            export AR=${pkgs.llvmPackages_23.llvm}/bin/llvm-ar RANLIB=${pkgs.llvmPackages_23.llvm}/bin/llvm-ranlib
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK:+$NIX_CFLAGS_LINK }-fuse-ld=lld"
          '';
        };
        # The bench shell and what zed's build needs besides (its own nix/build.nix lists the
        # same): `nix develop .#bench-zed`.
        devShells.bench-zed = pkgs.mkShell (bench // {
          packages = bench.packages ++ [ pkgs.cmake pkgs.protobuf ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.curl
            pkgs.fontconfig
            pkgs.freetype
            pkgs.libgit2
            pkgs.sqlite
            pkgs.zstd
            pkgs.glib
            pkgs.libva
            pkgs.vulkan-loader
            pkgs.libglvnd
            pkgs.libx11
            pkgs.libxcb
            pkgs.libdrm
            pkgs.libgbm
            pkgs.libxcomposite
            pkgs.libxdamage
            pkgs.libxext
            pkgs.libxfixes
            pkgs.libxrandr
          ];
          PROTOC = "${pkgs.protobuf}/bin/protoc";
        } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # zed's build script looks for glib's headers under /usr/include.
          CXXFLAGS = "-I${pkgs.glib.dev}/include/glib-2.0 -I${pkgs.glib.out}/lib/glib-2.0/include";
          ZSTD_SYS_USE_PKG_CONFIG = "1";
        } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # The WebRTC zed links statically, the build its build script would download into
          # every cold target directory.
          LK_CUSTOM_WEBRTC = pkgs.fetchzip {
            url = "https://github.com/zed-industries/livekit-rust-sdks/releases/download/webrtc-0001d84-4/webrtc-linux-x64-release.zip";
            sha256 = "0hlv1p6fi1lgfdyq8q49gghbqbqnq50icrw7i25g2qwqmpf2jyi7";
          };
        });
      });
}

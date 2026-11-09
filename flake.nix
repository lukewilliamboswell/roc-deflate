{
  description = "roc-deflate";

  nixConfig = {
    extra-substituters = [ "https://niclas-ahden.cachix.org" ];
    extra-trusted-public-keys = [ "niclas-ahden.cachix.org-1:FdGli1vBk0cTuVJV27Tau/JvlbW+Ly3pRwFByyqdke0=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The Roc compiler revision, keep the `?dir=src` at the end
    roc-src.url = "github:roc-lang/roc/ad3a5d2830b94fdac878ce1aaa73c64e7c57720f?dir=src";
    roc-nix = {
      url = "github:niclas-ahden/roc-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.roc-src.follows = "roc-src";
    };
  };

  outputs = { nixpkgs, flake-utils, roc-nix, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Builds Roc using `ReleaseFast`. To chase a suspected compiler fault,
        # build a `ReleaseSafe` variant of the same revision:
        #
        #   roc-nix.lib.${system}.mkRoc { optimize = "ReleaseSafe"; }
        #
        # roc-nix's README lists the rest of the build options, patches
        # included.
        roc = roc-nix.packages.${system}.roc;
      in
      {
        formatter = pkgs.nixpkgs-fmt;

        packages = {
          inherit roc;
          default = roc;
        };

        devShells = {
          default = pkgs.mkShell {
            # tests.roc drives gzip, and libdeflate's own libdeflate-gzip as
            # the reference our output must match byte for byte. The
            # benchmarks use curl and unzip to fetch the Silesia corpus (its
            # hashes are checked in Roc), build libdeflate from its source with
            # the shell's C compiler, and run both engines under mimalloc.
            # Providing them here means the scripts never assume host tools,
            # and cacert lets curl reach the mirror over HTTPS.
            buildInputs = [
              roc
              pkgs.watchexec
              pkgs.gzip
              pkgs.libdeflate
              pkgs.mimalloc
              pkgs.coreutils
              pkgs.curl
              pkgs.unzip
              pkgs.cacert
            ];

            shellHook = ''
              export ROC_LANGUAGE_SERVER_PATH=${roc}/bin/roc
              export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              export LIBDEFLATE_SRC=${pkgs.libdeflate.src}
              export MIMALLOC_LIB=${pkgs.mimalloc}/lib/libmimalloc${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
            '';
          };
        };
      });
}

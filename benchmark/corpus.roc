#!/usr/bin/env roc
## Fetch and verify the Silesia corpus into benchmark/.corpus, or into the
## directory given as the first argument.
##
## Each file is downloaded as a .zip from a GitHub mirror and checked against a
## pinned sha256 before extraction (see Silesia.roc). Files already extracted
## are left alone, so reruns are free. Needs curl and unzip, which the flake
## dev shell provides:
##
##     nix develop -c ./benchmark/corpus.roc [dest-dir]
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import Bench
import Silesia

main! = |args| {
	here = Bench.here!()
	Silesia.ensure!(Bench.arg(args, 0, "${here}/.corpus"))
}

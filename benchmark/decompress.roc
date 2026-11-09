#!/usr/bin/env roc
## Benchmark roc-deflate decompression against libdeflate across the Silesia
## corpus and print the per-corpus gap table.
##
##     ./benchmark/decompress.roc [rounds] [reps]
##
## For each corpus file this runs `rounds` interleaved pairs of (libdeflate,
## roc), each reporting the fastest of `reps` decompressions, and keeps each
## engine's best round, which cancels thermal drift between the two sides.
## Both engines decode the same libdeflate-level-6 raw DEFLATE stream into a
## caller-allocated buffer of exactly the output size, verify the result
## byte-for-byte against the original, and time only the decompression. Both
## run under mimalloc so allocator quality is not part of the comparison.
##
## CORPUS_FILES narrows the run to the space-separated names it lists, and ROC
## and CC override the compilers. The flake dev shell provides the rest: the
## libdeflate source (LIBDEFLATE_SRC), mimalloc (MIMALLOC_LIB), a C compiler,
## curl, and unzip. Outside it, clone ebiggers/libdeflate next to this repo and
## install mimalloc (brew install mimalloc / libmimalloc-dev).
##
##     nix develop -c ./benchmark/decompress.roc
##     CORPUS_FILES=xml nix develop -c ./benchmark/decompress.roc 1 2
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Stdout
import pf.Path
import Bench

main! = |args| {
	rounds = Bench.count!(args, 0, 3)?
	reps = Bench.count!(args, 1, 12)?
	here = Bench.here!()
	streams = "${here}/.streams"
	files = Bench.files!()

	libdeflate = Bench.prepare!(here)?
	Bench.build_c!(here, libdeflate, "dbench")?

	# The exact streams both engines decode: libdeflate level 6, raw DEFLATE.
	Path.create_all!(Path.utf8(streams)) ? |_| Exit(1)
	for name in files {
		stream = "${streams}/${name}.deflate"
		if !(Path.is_file!(Path.utf8(stream)) ? |_| Exit(1)) {
			Stdout.line!("generating stream: ${name}")?
			Bench.run!("${here}/.build/dbench", ["gen", "${here}/.corpus/${name}", stream])?
		}
	}

	Bench.build_roc!(here, "dtime")?
	env = Bench.mimalloc!()?

	# dtime counts its arguments past the first two, one per extra rep.
	extras = List.repeat("rep", reps - 1)

	Stdout.line!(Bench.row(["corpus", "c_mbps", "roc_mbps", "gap"]))?
	var $gaps = []
	for name in files {
		stream = "${streams}/${name}.deflate"
		original = "${here}/.corpus/${name}"
		best = Bench.best_of!(
			rounds,
			env,
			["${here}/.build/dbench", "bench", stream, original, reps.to_str()],
			["${here}/.build/dtime", stream, original].concat(extras),
		)?
		gap = Bench.gap(best)
		$gaps = $gaps.append(gap)
		Stdout.line!(Bench.row([name, best.c.to_str(), best.roc.to_str(), Bench.percent(gap)]))?
	}
	Stdout.line!("median gap: ${Bench.percent(Bench.median($gaps))}")
}

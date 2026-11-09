#!/usr/bin/env roc
## Benchmark roc-deflate compression against libdeflate across the Silesia
## corpus and print the per-corpus gap table.
##
##     ./benchmark/compress.roc [level] [rounds] [reps]
##
## For each corpus file this runs `rounds` interleaved pairs of (libdeflate,
## roc), each reporting the fastest of `reps` compressions, and keeps each
## engine's best round, which cancels thermal drift between the two sides.
## Both sides compress at the same level into a caller-allocated buffer sized
## by libdeflate's own bound, verify the result decompresses back to the
## input, and run under mimalloc so allocator quality is not part of the
## comparison. Throughput is over uncompressed bytes.
##
## The compressed streams are also compared byte for byte, since this
## implementation is a port of libdeflate's and should agree with it exactly.
##
## CORPUS_FILES narrows the run to the space-separated names it lists, and ROC
## and CC override the compilers. The flake dev shell provides the rest: the
## libdeflate source (LIBDEFLATE_SRC), mimalloc (MIMALLOC_LIB), a C compiler,
## curl, and unzip. Outside it, clone ebiggers/libdeflate next to this repo and
## install mimalloc (brew install mimalloc / libmimalloc-dev).
##
##     nix develop -c ./benchmark/compress.roc 6
##     CORPUS_FILES="xml dickens" nix develop -c ./benchmark/compress.roc 1 1 2
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Stdout
import pf.Path
import Bench

main! = |args| {
	level = Bench.level!(args, 0, "6")?
	rounds = Bench.count!(args, 1, 3)?
	reps = Bench.count!(args, 2, 5)?
	here = Bench.here!()
	work = "${here}/.work"

	libdeflate = Bench.prepare!(here)?
	Path.create_all!(Path.utf8(work)) ? |_| Exit(1)
	Bench.build_c!(here, libdeflate, "cbench")?
	Bench.build_roc!(here, "ctime")?
	env = Bench.mimalloc!()?

	Stdout.line!("compression level ${level}, best of ${rounds.to_str()} rounds of min-of-${reps.to_str()}")?
	Stdout.line!(Bench.row(["corpus", "c_mbps", "roc_mbps", "gap", "size", "bytes"]))?
	var $gaps = []
	for name in Bench.files!() {
		input = "${here}/.corpus/${name}"
		c_out = "${work}/c_${name}.deflate"
		roc_out = "${work}/roc_${name}.deflate"
		best = Bench.best_of!(
			rounds,
			env,
			["${here}/.build/cbench", input, level, reps.to_str(), c_out],
			["${here}/.build/ctime", input, level, reps.to_str(), roc_out],
		)?
		gap = Bench.gap(best)
		$gaps = $gaps.append(gap)
		roc_stream = Path.read_bytes!(Path.utf8(roc_out)) ? |_| Exit(1)
		c_stream = Path.read_bytes!(Path.utf8(c_out)) ? |_| Exit(1)
		bytes = if c_stream == roc_stream "identical" else "DIFFER"
		Stdout.line!(Bench.row([name, best.c.to_str(), best.roc.to_str(), Bench.percent(gap), roc_stream.len().to_str(), bytes]))?
	}
	Stdout.line!("median gap: ${Bench.percent(Bench.median($gaps))}")
}

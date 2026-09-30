## Benchmark Deflate on a corpus under the same measurement protocol the C
## reference benchmark uses, and emit the same TSV so benchmark/compare.sh can
## put the two side by side.
##
## Matching the protocol is the whole point. Comparing a single wall-clock run
## against a best-of-N one says nothing about the implementations, so every
## detail here mirrors benchmark/c/cbench.c:
##
##   - one untimed warmup, so the first timed pass is not paying startup costs
##   - iterate until there are both `min_iters` samples and `min_ns` of elapsed
##     time, capped by `max_ns` so the slowest levels stay tolerable
##   - report the fastest iteration, which is the one least disturbed by
##     scheduling and reproduces across machines under load
##   - throughput is uncompressed bytes per second in both directions
##   - the round trip is checked before anything is reported, so a fast wrong
##     answer cannot be mistaken for a fast right one
##
## One difference is real and not a protocol choice: cbench reuses a single
## compressor object across iterations, because that is how libdeflate is meant
## to be called. `Deflate.compress` has no such object, so it does whatever
## setup it needs on every call. That is a property of this API rather than of
## the measurement, and it is left visible instead of tuned away.
##
##     roc build --opt=speed benchmark/benchmark.roc --output=benchmark/benchmark
##     ./benchmark/benchmark benchmark/.corpus > roc.tsv
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import pf.Path
import pf.Utc
import pf.IOErr exposing [IOErr]
import pf.OsStr exposing [OsStr]
import deflate.Deflate

# The 12 Silesia files, in the corpus's canonical order.
names = [
	"dickens", "mozilla", "mr", "nci", "ooffice", "osdb",
	"reymont", "samba", "sao", "webster", "x-ray", "xml",
]

# The same budget cbench uses by default.
min_iters = 5
min_ns = 400_000_000
max_ns = 8_000_000_000
max_iters = 200

Timing : { best_ns : U128, iters : U64 }

main! = |args| {
	dir_os = match args.get(1) {
		Ok(raw) => OsStr.from_raw(raw)
		Err(_) => OsStr.from_str("benchmark/.corpus")
	}
	dir = Path.from_os_str(dir_os)

	Stdout.line!("file\tengine\top\tsetting\torig\tcomp\tbest_ns\titers")?
	run_all!(dir, names)
}

run_all! : Path.Path, List(Str) => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
run_all! = |dir, remaining|
	match remaining {
		[] => Ok({})
		[name, .. as rest] => {
			run_one!(dir, name)?
			run_all!(dir, rest)
		}
	}

run_one! : Path.Path, Str => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
run_one! = |dir, name| {
	bytes = Path.read_bytes!(dir.join(name)) ? |_| Exit(1)
	report!(name, "fastest", bytes, 1)?
	report!(name, "balanced", bytes, 6)?
	report!(name, "smallest", bytes, 12)
}

## Time both directions at one level and print the two rows.
report! : Str, Str, List(U8), U64 => Try({}, [Exit(I32), StdoutErr(IOErr), ..])
report! = |name, setting, bytes, level| {
	orig = bytes.len()
	compressed = Deflate.compress(bytes, level) ? |_| Exit(1)
	comp = compressed.len()

	# Verify before reporting: a fast wrong answer is not a result.
	round_tripped = Deflate.decompress(compressed) ? |_| Exit(1)
	verified = if round_tripped == bytes { Ok({}) } else { Err(Exit(1)) }
	verified?

	ct = time_compress!(bytes, level)
	row!(name, "compress", setting, orig, comp, ct)?
	dt = time_decompress!(compressed, orig)
	row!(name, "decomp", setting, orig, comp, dt)
}

row! : Str, Str, Str, U64, U64, Timing => Try({}, [StdoutErr(IOErr), ..])
row! = |name, op, setting, orig, comp, t|
	Stdout.line!("${name}\troc-deflate\t${op}\t${setting}\t${orig.to_str()}\t${comp.to_str()}\t${t.best_ns.to_str()}\t${t.iters.to_str()}")

## Repeat until there are enough samples and enough elapsed time, keeping the
## fastest. One warmup pass runs first, outside the loop and untimed.
##
## Written as recursion rather than a `while` over mutable state because the
## latter currently crashes the compiler in spec_constr on this shape; the
## measurement protocol is unaffected.
time_compress! : List(U8), U64 => Timing
time_compress! = |bytes, level| {
	warm = compressed_len(Deflate.compress(bytes, level))
	compress_loop!(bytes, level, warm, 0, 0, 0)
}

compress_loop! : List(U8), U64, U64, U128, U128, U64 => Timing
compress_loop! = |bytes, level, sink, best, elapsed, iters|
	if sink == 0 {
		# Unreachable: keeps the accumulated sizes observable so the compressed
		# output cannot be discarded as unused.
		{ best_ns: 0, iters: 0 }
	} else if iters >= max_iters or elapsed >= max_ns or (iters >= min_iters and elapsed >= min_ns) {
		{ best_ns: best, iters: iters }
	} else {
		start = Utc.now!()
		out = Deflate.compress(bytes, level)
		# Read the length before stopping the clock so the work is forced.
		produced = compressed_len(out)
		finish = Utc.now!()
		took = Utc.delta_as_nanos(finish, start)
		next_best = if iters == 0 or took < best { took } else { best }
		compress_loop!(bytes, level, sink + produced, next_best, elapsed + took, iters + 1)
	}

## Length of a compressed result, or 0 if it failed; report! has already
## verified the round trip, so a failure here cannot pass as a result.
compressed_len : Try(List(U8), _) -> U64
compressed_len = |result|
	match result {
		Ok(bytes) => bytes.len()
		Err(_) => 0
	}

## Length of a decompressed result, or 0 if it failed.
decompressed_len : Try(List(U8), _) -> U64
decompressed_len = |result|
	match result {
		Ok(bytes) => bytes.len()
		Err(_) => 0
	}

time_decompress! : List(U8), U64 => Timing
time_decompress! = |compressed, expected_len| {
	warm = decompressed_len(Deflate.decompress(compressed))
	decompress_loop!(compressed, expected_len + warm, 0, 0, 0)
}

decompress_loop! : List(U8), U64, U128, U128, U64 => Timing
decompress_loop! = |compressed, sink, best, elapsed, iters|
	if sink == 0 {
		{ best_ns: 0, iters: 0 }
	} else if iters >= max_iters or elapsed >= max_ns or (iters >= min_iters and elapsed >= min_ns) {
		{ best_ns: best, iters: iters }
	} else {
		start = Utc.now!()
		out = Deflate.decompress(compressed)
		produced = decompressed_len(out)
		finish = Utc.now!()
		took = Utc.delta_as_nanos(finish, start)
		next_best = if iters == 0 or took < best { took } else { best }
		decompress_loop!(compressed, sink + produced, next_best, elapsed + took, iters + 1)
	}

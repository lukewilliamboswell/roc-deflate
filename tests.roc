#!/usr/bin/env roc
## All tests: the package's `expect` blocks, then interop with gzip and
## libdeflate with the edge-length sweep and the decoder's error checks, then
## the compression-ratio gate.
##
## The `expect` blocks in package/ are the quick ones: hand-built streams that
## pin the decoder to the format, and short round trips at every level.
## tests/harness.roc generates a corpus in memory, drives real gzip and
## libdeflate-gzip through the platform's Cmd, and compares bytes in-process.
## Forward proves our streams decode under real gzip, reverse proves we inflate
## real gzip's streams, and libdeflate proves our output is the same bytes as
## the library this package ports, at every level and at the input lengths
## where some level changes behavior. tests/ratios.roc compresses the committed
## Canterbury corpus and fails on a ratio regression.
##
## harness and ratios are built with --opt=speed, the LLVM backend the README
## numbers come from, so both exercise the same code the benchmark measures.
## gzip and libdeflate-gzip are the only external tools, and the flake dev
## shell provides them:
##
##     nix develop -c ./tests.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.OsStr

main! = |_| {
	Stdout.line!("== unit tests")?
	run!("roc", ["test", "package/main.roc"])?

	Stdout.line!("== interop, edge lengths, and decoder errors (compiled --opt=speed)")?
	build!("tests/harness.roc", "tests/harness")?
	run!("./tests/harness", [])?

	Stdout.line!("== compression-ratio gate (compiled --opt=speed)")?
	build!("tests/ratios.roc", "tests/ratios")?
	run!("./tests/ratios", [])?
	Ok({})
}

# Build a .roc file to a named binary with the LLVM speed backend.
build! : Str, Str => Try({}, [Exit(I32)])
build! = |src, out| run!("roc", ["build", "--opt=speed", src, "--output=${out}"])

# Run a command with inherited stdio, failing the script on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32)])
run! = |program, arguments| {
	Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).call!() ? |_| Exit(1)
	Ok({})
}

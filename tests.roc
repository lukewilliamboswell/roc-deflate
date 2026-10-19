#!/usr/bin/env roc
## All tests: gzip interop in both directions and a round-trip at every level,
## then the compression-ratio gate.
##
## tests/harness.roc generates a corpus in memory, drives real gzip through the
## platform's Cmd, and compares bytes in-process. Forward proves our streams
## decode under real gzip; reverse proves we inflate real gzip's streams; the
## round-trip covers every level, including the ones gzip interop skips.
## tests/ratios.roc compresses the committed Canterbury corpus and fails on a
## ratio regression.
##
## harness and ratios are built with --opt=speed, the LLVM backend the README
## numbers come from, so both exercise the same code the benchmark measures.
## gzip is the only external tool, and the flake dev shell provides it:
##
##     nix develop -c ./tests.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.OsStr

main! = |_| {
	Stdout.line!("== interop and round-trips (compiled --opt=speed)")?
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
	Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).exec!() ? |_| Exit(1)
	Ok({})
}

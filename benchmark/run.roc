#!/usr/bin/env roc
## Run the Silesia benchmark. Downloads and verifies the corpus on first use,
## then builds benchmark/benchmark.roc with --opt=speed (the LLVM backend the
## README numbers come from) and runs it.
##
## The corpus lives in benchmark/.corpus (gitignored) and is fetched per file
## from a GitHub mirror, each verified against the sha256 of its .zip so a
## corrupt or swapped download fails loudly instead of skewing the numbers.
## Files already present are left untouched, so reruns skip the download.
##
## Needs roc, curl, unzip, gzip, and sha256sum; run from the repository root:
##
##     nix develop -c ./benchmark/run.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
}

import pf.Stdout
import pf.Path
import pf.Cmd
import pf.IOErr exposing [IOErr]
import pf.OsStr exposing [OsStr]

corpus_dir = "benchmark/.corpus"
mirror = "https://raw.githubusercontent.com/MiloszKrajewski/SilesiaCorpus/master"

# Each Silesia file with the sha256 of its .zip on the mirror.
files = [
	{ name: "dickens", sha: "b0fcae3adb0334b5b3b73b1d1d06edfc5839c0bb7561255e0c490ab4682b46cc" },
	{ name: "mozilla", sha: "3abdbd504073eda475f5d3d3ee7a69460db465065c329c73dd37ba3a082b8088" },
	{ name: "mr", sha: "bfb3e0735c7d275d22b3bc5d142e3f5431aacb7d3f7d329c6c9fe51dc1dfea2e" },
	{ name: "nci", sha: "2982cb2a3fd9360735c74997b2e60f63b2f0a6a3941167cb0021f45dc0225a02" },
	{ name: "ooffice", sha: "909880ebf9fc5702036b921935345450c43f9e352a6acb32100babafcf8f1d30" },
	{ name: "osdb", sha: "a1955a73be3ef1b1b14ab73c75e45e2c5c013c9bbbcaec277e58a94f732eeb1b" },
	{ name: "reymont", sha: "691069ebbcf881d2e5177c0ff81711008209e6bd824e07a90e703451fb96d9c2" },
	{ name: "samba", sha: "285c06096c0e24b71e28705f489932482b23d823b306dddc1cd8d0a8145121a1" },
	{ name: "sao", sha: "eeb657d7511dbdff833853157249506b61cde55a3223f2013e88cbbdb934c36f" },
	{ name: "webster", sha: "6495af470253ced7d60e616a2b2f2f2841a88ea55bfd23cf0f1d46daa808f937" },
	{ name: "x-ray", sha: "f3d111158444a6cb42e7e60a46582755083c58f1657a55613f0edd64c5626ec6" },
	{ name: "xml", sha: "feeac237babe74e77ca1b7cd72d651ab0a722218ee3d2c07d519625b1a60fe50" },
]

main! = |_| {
	Path.create_all!(Path.from_os_str(OsStr.from_str(corpus_dir))) ? |_| Exit(1)
	Stdout.line!("== ensuring Silesia corpus in ${corpus_dir}")?
	ensure_all!(files)?

	Stdout.line!("== building benchmark (--opt=speed)")?
	run!("roc", ["build", "--opt=speed", "benchmark/benchmark.roc", "--output=benchmark/benchmark"])?

	Stdout.line!("== results")?
	run!("./benchmark/benchmark", [corpus_dir])?
	Ok({})
}

# Ensure every corpus file is present, fetching the missing ones.
ensure_all! : List({ name : Str, sha : Str }) => Try({}, [Exit(I32), StdoutErr(IOErr)])
ensure_all! = |remaining|
	match remaining {
		[] => Ok({})
		[f, .. as rest] => {
			ensure_one!(f)?
			ensure_all!(rest)
		}
	}

# Download, verify, and extract one file unless it is already extracted.
ensure_one! : { name : Str, sha : Str } => Try({}, [Exit(I32), StdoutErr(IOErr)])
ensure_one! = |{ name, sha }| {
	extracted = Path.from_os_str(OsStr.from_str("${corpus_dir}/${name}"))
	if Path.is_file!(extracted) ? |_| Exit(1) {
		Stdout.line!("  ${name}: present")
	} else {
		zip = "${corpus_dir}/${name}.zip"
		Stdout.line!("  ${name}: downloading")?
		run!("curl", ["-fsSL", "--retry", "3", "-o", zip, "${mirror}/${name}.zip"])?
		out = Cmd.new(OsStr.from_str("sha256sum")).args([OsStr.from_str(zip)]).exec_output!() ? |_| Exit(1)
		if out.stdout_utf8.contains(sha) {
			run!("unzip", ["-oq", zip, "-d", corpus_dir])?
			Stdout.line!("  ${name}: verified and extracted")
		} else {
			Stdout.line!("  ${name}: SHA256 MISMATCH, expected ${sha}")?
			Err(Exit(1))
		}
	}
}

# Run a command with inherited stdio, failing the script on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32)])
run! = |program, arguments| {
	Cmd.exec!(OsStr.from_str(program), arguments.map(OsStr.from_str)) ? |_| Exit(1)
	Ok({})
}

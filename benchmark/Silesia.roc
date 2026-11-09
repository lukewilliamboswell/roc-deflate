## The Silesia corpus: its twelve files and the fetch that puts them in place.
##
## Each file is downloaded as a .zip from a GitHub mirror and checked against a
## pinned sha256 before extraction, so a corrupt or swapped download fails
## loudly instead of quietly skewing benchmark numbers. Files already extracted
## are left alone, so reruns are free. Needs curl and unzip.

import pf.Cmd
import pf.Path
import pf.Stdout
import pf.Stderr
import pf.IOErr
import pf.OsStr

Silesia := [].{

	## The file names, in the corpus's canonical order.
	names : List(Str)
	names = files.map(|file| file.name)

	## Fetch, verify, and extract every file missing from `dir`, creating the
	## directory first if needed.
	ensure! : Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr), StderrErr(IOErr)])
	ensure! = |dir| {
		Path.create_all!(Path.utf8(dir)) ? |_| Exit(1)
		for file in files {
			ensure_one!(dir, file)?
		}
		Stdout.line!("corpus ready in ${dir}")
	}
}

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

# Download, verify, and extract one file unless it is already extracted. The
# hash is checked in-process, so no sha256sum or shasum is needed.
ensure_one! : Str, { name : Str, sha : Str } => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr), StderrErr(IOErr)])
ensure_one! = |dir, { name, sha }| {
	if Path.is_file!(Path.utf8("${dir}/${name}")) ? |_| Exit(1) {
		return Ok({})
	}
	zip = "${dir}/${name}.zip"
	Stdout.line!("  ${name}: downloading")?
	run!("curl", ["-fsSL", "--retry", "3", "-o", zip, "${mirror}/${name}.zip"])?
	got = Crypto.SHA256.hash(Path.read_bytes!(Path.utf8(zip)) ? |_| Exit(1)).to_hex()
	if got != sha {
		Stderr.line!("  ${name}: SHA256 MISMATCH")?
		Stderr.line!("    expected ${sha}")?
		Stderr.line!("    got      ${got}")?
		Path.delete!(Path.utf8(zip)) ? |_| Exit(1)
		return Err(Exit(1))
	}
	run!("unzip", ["-oq", zip, "-d", dir])?
	Path.delete!(Path.utf8(zip)) ? |_| Exit(1)
	Ok({})
}

# Run a command with inherited stdio, failing on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32)])
run! = |program, arguments| {
	Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).call!() ? |_| Exit(1)
	Ok({})
}

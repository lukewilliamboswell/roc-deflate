## What benchmark/compress.roc and benchmark/decompress.roc share: reading the
## arguments, finding libdeflate and mimalloc, building the two drivers when
## they are stale, running them, and turning their throughputs into the gap
## table.
##
## Every driver prints one tab-separated line whose third field is MB/s over
## uncompressed bytes, so both scripts read results the same way.

import pf.Cmd
import pf.Env
import pf.Path
import pf.Stdout
import pf.Stderr
import pf.System
import pf.IOErr
import pf.OsStr
import Silesia

Bench := [].{

	## The directory holding the running script. The launcher passes the
	## script's path as the program name, so the scripts work from any
	## directory.
	here! : () => Str
	here! = || {
		script = (Env.program_name!() ?? "").to_str_try() ?? ""
		match script.split_last("/") {
			Ok({ before, after: _ }) => before
			Err(NotFound) => "."
		}
	}

	## The positional argument at `index`, or `fallback` when it is absent.
	arg : List(OsStr), U64, Str -> Str
	arg = |args, index, fallback|
		match args.get(index) {
			Ok(value) => value.to_str_try() ?? fallback
			Err(OutOfBounds) => fallback
		}

	## The positional argument at `index` as a count of at least one, or
	## `fallback` when it is absent.
	count! : List(OsStr), U64, U64 => Try(U64, [Exit(I32), Interrupted, StderrErr(IOErr)])
	count! = |args, index, fallback| {
		text = arg(args, index, fallback.to_str())
		count = U64.from_str(text) ?? 0
		if count == 0 {
			Stderr.line!("expected a positive whole number, got: ${text}")?
			Err(Exit(2))
		} else {
			Ok(count)
		}
	}

	## The positional argument at `index` as a compression level from 1 to 12,
	## or `fallback` when it is absent. libdeflate's level 0 only stores, so
	## there is nothing to compare.
	level! : List(OsStr), U64, Str => Try(Str, [Exit(I32), Interrupted, StderrErr(IOErr)])
	level! = |args, index, fallback| {
		text = arg(args, index, fallback)
		match U64.from_str(text) {
			Ok(n) if n >= 1 and n <= 12 => Ok(text)
			_ => {
				Stderr.line!("expected a level from 1 to 12, got: ${text}")?
				Err(Exit(2))
			}
		}
	}

	## The corpus files to run: all of Silesia, or the space-separated names in
	## CORPUS_FILES for a quicker run.
	files! : () => List(Str)
	files! = || {
		listed = var_or!("CORPUS_FILES", "").split_on(" ").keep_if(|name| !name.is_empty())
		if listed.is_empty() Silesia.names else listed
	}

	## Find the libdeflate source and fetch the corpus into `<here>/.corpus`.
	## The source comes from LIBDEFLATE_SRC, which the flake dev shell sets,
	## or a checkout next to this repo.
	prepare! : Str => Try(Str, [Exit(I32), Interrupted, StdoutErr(IOErr), StderrErr(IOErr)])
	prepare! = |here| {
		src = var_or!("LIBDEFLATE_SRC", "${here}/../../libdeflate")
		if !(Path.is_file!(Path.utf8("${src}/libdeflate.h")) ?? False) {
			Stderr.line!("missing libdeflate checkout: ${src}")?
			Stderr.line!("clone ebiggers/libdeflate next to this repo, or set LIBDEFLATE_SRC")?
			return Err(Exit(1))
		}
		Silesia.ensure!("${here}/.corpus")?
		Path.create_all!(Path.utf8("${here}/.build")) ? |_| Exit(1)
		Ok(src)
	}

	## Build the C driver `<here>/<name>.c` into `<here>/.build/<name>` when the
	## binary is missing or older than its source. libdeflate is compiled in at
	## -O3, matching what --opt=speed gives the Roc side.
	build_c! : Str, Str, Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
	build_c! = |here, src, name| {
		out = "${here}/.build/${name}"
		source = "${here}/${name}.c"
		if stale!(out, [source]) {
			Stdout.line!("building ${name}")?
			run!(var_or!("CC", "cc"), ["-O3", "-I${src}", "-o", out, source].concat(c_sources!(src)?))?
		}
		Ok({})
	}

	## Build the Roc harness `<here>/<name>.roc` with --opt=speed into
	## `<here>/.build/<name>`. It is rebuilt when the harness, any package
	## source, or the compiler itself is newer than the binary, since checking
	## only the harness silently benchmarks a stale compressor.
	build_roc! : Str, Str => Try({}, [Exit(I32), Interrupted, StdoutErr(IOErr)])
	build_roc! = |here, name| {
		roc = var_or!("ROC", "roc")
		out = "${here}/.build/${name}"
		source = "${here}/${name}.roc"
		modules = Path.list!(Path.utf8("${here}/../package")) ? |_| Exit(1)
		sources = [source]
			.concat(modules.map(Path.display).keep_if(|path| path.ends_with(".roc")))
			.concat(which!(roc))
		if stale!(out, sources) {
			Stdout.line!("building ${name} (roc --opt=speed)")?
			run!(roc, ["build", "--opt=speed", source, "--output=${out}"])?
		}
		Ok({})
	}

	## The environment that runs a driver under mimalloc, so allocator quality
	## is not part of the comparison. MIMALLOC_LIB, which the flake dev shell
	## sets, comes first, then ldconfig on Linux or Homebrew on macOS. Only the
	## timed runs get it, not the builds.
	mimalloc! : () => Try(List((OsStr, OsStr)), [Interrupted, StderrErr(IOErr)])
	mimalloc! = || {
		macos =
			match System.target!().os() {
				MacOS(_) => True
				_ => False
			}
		from_env = var_or!("MIMALLOC_LIB", "")
		lib =
			if readable!(from_env) {
				from_env
			} else if macos {
				brew_mimalloc!()
			} else {
				ldconfig_mimalloc!()
			}
		if readable!(lib) {
			preload = if macos "DYLD_INSERT_LIBRARIES" else "LD_PRELOAD"
			Ok([(OsStr.from_str(preload), OsStr.from_str(lib))])
		} else {
			Stderr.line!("warning: mimalloc not found, running with the system allocator")?
			Ok([])
		}
	}

	## Run two drivers `rounds` times, interleaved, and keep each one's best
	## MB/s. Interleaving spreads thermal drift evenly over both sides. Each
	## command is a program followed by its arguments.
	best_of! : U64, List((OsStr, OsStr)), List(Str), List(Str) => Try({ c : Dec, roc : Dec }, [Exit(I32), Interrupted, StderrErr(IOErr), BadDriverOutput(Str)])
	best_of! = |rounds, env, c_command, roc_command| {
		var $c = 0.Dec
		var $roc = 0.Dec
		var $round = 0.U64
		while $round < rounds {
			$c = Dec.max($c, mbps!(c_command, env)?)
			$roc = Dec.max($roc, mbps!(roc_command, env)?)
			$round = $round + 1
		}
		Ok({ c: $c, roc: $roc })
	}

	## How much faster libdeflate is than roc-deflate, in percent.
	gap : { c : Dec, roc : Dec } -> Dec
	gap = |best| (best.c - best.roc) / best.roc * 100

	## A percentage with its sign and one decimal place, like `+12.3%`.
	percent : Dec -> Str
	percent = |value| {
		tenths = (value * 10).round().to_attos() // 1_000_000_000_000_000_000
		sign = if tenths < 0 "-" else "+"
		magnitude = tenths.abs()
		"${sign}${(magnitude // 10).to_str()}.${(magnitude % 10).to_str()}%"
	}

	## The middle value, or the mean of the two middle ones for an even count.
	median : List(Dec) -> Dec
	median = |values| {
		sorted = values.sort()
		middle = sorted.len() // 2
		upper = sorted.get(middle) ?? 0
		if sorted.len() % 2 == 1 {
			upper
		} else {
			((sorted.get(middle - 1) ?? 0) + upper) / 2
		}
	}

	## One table line: the corpus name left-aligned, the numbers right-aligned,
	## each in a fixed-width column.
	row : List(Str) -> Str
	row = |cells| {
		padded = cells.map_with_index(
			|cell, index| {
				width = widths.get(index) ?? 0
				pad = Str.repeat(" ", width.minus_saturated(cell.count_utf8_bytes()))
				if index == 0 cell.concat(pad) else pad.concat(cell)
			},
		)
		Str.join_with(padded, " ")
	}

	## Run a command with inherited stdio, failing on a nonzero exit.
	run! : Str, List(Str) => Try({}, [Exit(I32)])
	run! = |program, arguments| {
		Cmd.new(OsStr.from_str(program)).args(arguments.map(OsStr.from_str)).call!() ? |_| Exit(1)
		Ok({})
	}
}

widths = [9, 10, 10, 8, 12, 9]

# An environment variable, or `fallback` when it is unset or empty, as with
# the shell's `${NAME:-fallback}`.
var_or! : Str, Str => Str
var_or! = |name, fallback| {
	value = Env.var_str!(OsStr.from_str(name)) ?? ""
	if value.is_empty() fallback else value
}

# Whether the path leads to a readable file. Unlike Path.is_file!, this
# follows symbolic links, which is what a nix store library path is.
readable! : Str => Bool
readable! = |path| !path.is_empty() and (Path.is_readable!(Path.utf8(path)) ?? False)

# Whether `target` is missing or older than any of `sources`, as with the
# shell's `[ ! -x target ] || [ source -nt target ]`.
stale! : Str, List(Str) => Bool
stale! = |target, sources| {
	if !(Path.is_executable!(Path.utf8(target)) ?? False) {
		return True
	}
	built =
		match Path.time_modified!(Path.utf8(target)) {
			Ok(time) => time
			Err(_) => return True
		}
	for source in sources {
		newer =
			match Path.time_modified!(Path.utf8(source)) {
				Ok(time) => time > built
				Err(_) => False
			}
		if newer {
			return True
		}
	}
	False
}

# Where `command -v` would find a program: the name itself when it holds a
# slash, or else the first executable of that name on PATH. Empty when there
# is none, so the result can be appended to a list of sources.
which! : Str => List(Str)
which! = |program| {
	if program.contains("/") {
		return [program]
	}
	for dir in var_or!("PATH", "").split_on(":") {
		candidate = "${dir}/${program}"
		if !dir.is_empty() and (Path.is_executable!(Path.utf8(candidate)) ?? False) {
			return [candidate]
		}
	}
	[]
}

# libdeflate's lib/*.c and lib/*/*.c, which is every file its own build
# compiles.
c_sources! : Str => Try(List(Str), [Exit(I32)])
c_sources! = |src| {
	top = Path.list!(Path.utf8("${src}/lib")) ? |_| Exit(1)
	var $all = top
	for entry in top {
		if Path.is_dir!(entry) ?? False {
			$all = $all.concat(Path.list!(entry) ? |_| Exit(1))
		}
	}
	Ok($all.map(Path.display).keep_if(|path| path.ends_with(".c")))
}

# The library under Homebrew's mimalloc prefix. Without brew this names a path
# that does not exist, which the caller reports.
brew_mimalloc! : () => Str
brew_mimalloc! = || {
	prefix = Cmd.new("brew").args(["--prefix", "mimalloc"]).stderr(Null).capture!() ?? ""
	"${prefix.trim()}/lib/libmimalloc.dylib"
}

# The first libmimalloc.so in the dynamic linker's cache, or "" without one.
ldconfig_mimalloc! : () => Str
ldconfig_mimalloc! = || {
	cache = Cmd.new("ldconfig").arg("-p").stderr(Null).capture!() ?? ""
	match cache.split_on("\n").find_first(|line| line.contains("libmimalloc.so")) {
		Ok(line) => line.trim().split_on(" ").last() ?? ""
		Err(NotFound) => ""
	}
}

# Run a driver and read the MB/s from the third field of the tab-separated
# line it prints. A failing driver's stdout is passed on, since that is where
# the harnesses report a verification failure.
mbps! : List(Str), List((OsStr, OsStr)) => Try(Dec, [Exit(I32), Interrupted, StderrErr(IOErr), BadDriverOutput(Str)])
mbps! = |command, env| {
	cmd = Cmd.new(OsStr.from_str(command.first() ?? "")).args(command.drop_first(1).map(OsStr.from_str)).envs(env)
	match cmd.capture!() {
		Ok(line) => Dec.from_str(line.trim().split_on("\t").get(2) ?? "").map_err(|_| BadDriverOutput(line))
		Err(BadExitStatus(output)) => {
			Stderr.line!("${cmd.to_str()} failed")?
			Stderr.write_bytes!(output.stdout_bytes)?
			Err(Exit(1))
		}
		Err(_) => {
			Stderr.line!("${cmd.to_str()} could not run")?
			Err(Exit(1))
		}
	}
}

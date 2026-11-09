#!/usr/bin/env roc
## Every fuzz target: build it, run its declared examples with their
## allocation ceilings, then explore with coverage feedback.
##
##     ./fuzz.roc            # a two-second smoke run of each, as tests.roc does
##     ./fuzz.roc 600        # ten minutes of exploration each
##
## A target is `fuzz/<name>.roc` with a lowercase name; capitalised files there
## are modules the targets share. Executables, corpora and reports go under
## `.fuzz/`, and a corpus is kept between runs, so a longer campaign starts
## where the last one stopped. A build failure, failed example, exceeded
## ceiling or finding fails the run, and the report says how to replay and
## minimize it. Targets keep no allocation baselines: their ceilings are
## written in the targets themselves.
##
## roc-fuzz runs on Linux x86-64 and Apple Silicon macOS.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout

main! = |args| {
	seconds = match args.get(0) {
		Ok(arg) => OsStr.display(arg)
		Err(_) => "2"
	}
	names = target_names!()?
	if names.is_empty() {
		Stderr.line!("error: no fuzz targets under fuzz/")?
		return Err(Exit(1))
	}
	Path.create_all!(Path.utf8(".fuzz/reports")) ? |_| Exit(1)
	var $failed = []
	for name in names {
		Stdout.line!("== ${name}")?
		executable = ".fuzz/${name}"
		corpus = ".fuzz/corpus/${name}"
		report = ".fuzz/reports/${name}"
		Path.create_all!(Path.utf8(corpus)) ? |_| Exit(1)
		match Path.delete_all!(Path.utf8(report)) {
			_ => {}
		}
		steps = [
			["roc", "build", "--fuzz", "--opt=speed", "fuzz/${name}.roc", "--output=${executable}"],
			[executable, "run", corpus, "--time=${seconds}", "--max-input-size=8192", "--timeout=30", "--report-dir=${report}"],
		]
		var $ok = True
		for argv in steps {
			if $ok {
				$ok = step!(argv)?
			}
		}
		if !$ok {
			$failed = List.append($failed, name)
		}
	}
	if $failed.is_empty() {
		Stdout.line!("All ${names.len().to_str()} fuzz targets passed")?
		Ok({})
	} else {
		Stderr.line!("Failed: ${Str.join_with($failed, ", ")}")?
		Err(Exit(1))
	}
}

# The name of every lowercase `fuzz/<name>.roc`.
target_names! : () => Try(List(Str), [Exit(I32)])
target_names! = || {
	entries = Path.list!(Path.utf8("fuzz")) ? |_| Exit(1)
	var $names = []
	for entry in entries {
		file = Path.display(entry).split_on("/").last() ?? ""
		first = List.first(file.to_utf8()) ?? 0
		if file.ends_with(".roc") and first >= 'a' and first <= 'z' {
			$names = List.append($names, file.drop_suffix(".roc"))
		}
	}
	Ok($names)
}

# Print a command, run it with inherited output, and report whether it succeeded.
step! : List(Str) => Try(Bool, [Exit(I32), Interrupted, StdoutErr(_)])
step! = |argv| {
	Stdout.line!("+ ${Str.join_with(argv, " ")}")?
	match argv {
		[program, .. as rest] =>
			match Cmd.new(OsStr.from_str(program)).args(rest.map(OsStr.from_str)).call!() {
				Ok({}) => Ok(True)
				Err(Interrupted) => Err(Interrupted)
				Err(_) => Ok(False)
			}
		[] => Ok(False)
	}
}

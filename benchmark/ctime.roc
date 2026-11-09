app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import pf.Path
import pf.OsStr
import pf.Monotonic
import deflate.Deflate

# usage: ctime <original> <level> <reps> <out.deflate>
#
# Verifies the compressed stream decompresses back to the input, writes it out
# so it can be compared against libdeflate's, then times the repetitions, each
# compressing into one reused output buffer, and prints:
# roc\t<min_ns>\t<mbps>\t<compressed_size>
main! = |args| {
	path_os = List.get(args, 0) ? |_| Exit(1)
	level_os = List.get(args, 1) ? |_| Exit(2)
	reps_os = List.get(args, 2) ? |_| Exit(3)
	out_os = List.get(args, 3) ? |_| Exit(4)
	level_number = U64.from_str(OsStr.to_str_try(level_os) ? |_| Exit(2)) ? |_| Exit(2)
	level = Deflate.Level.from_u64(level_number) ? |_| Exit(2)
	reps = U64.from_str(OsStr.to_str_try(reps_os) ? |_| Exit(3)) ? |_| Exit(3)
	data = Path.read_bytes!(Path.from_os_str(path_os)) ? |_| Exit(5)

	first = Deflate.compress(data, level)
	back = Deflate.decompress(first, {}) ? |_| Exit(7)
	if back != data {
		Stdout.line!("VERIFY FAIL") ? |_| Exit(8)
		return Err(Exit(8))
	} else {
	}
	Path.write_bytes!(Path.from_os_str(out_os), first) ? |_| Exit(9)

	in_len = List.len(data)
	compressed_len = List.len(first)
	var $best = 0.U128
	var $total = 0.U64
	var $r = 0.U64
	# One output buffer for every repetition, as cbench reuses one: it is
	# emptied outside the timed region, keeping its capacity, and compressed
	# into, so its memory is reused rather than fetched again each time.
	var $buf = List.with_capacity(Deflate.compress_bound(in_len))
	while $r < reps {
		buf0 = List.clear($buf)
		t0 = Monotonic.now!()
		$buf = Deflate.compress_into(data, level, buf0)
		sz = List.len($buf)
		dt = Monotonic.now!().since(t0).to_nanos().to_u128()
		$total = $total + sz
		if $r == 0 or dt < $best {
			$best = dt
		}
		$r = $r + 1
	}
	mbps_x10 = (in_len.to_u128() * 10_000) // $best
	Stdout.line!("roc\t${$best.to_str()}\t${(mbps_x10 // 10).to_str()}.${(mbps_x10 % 10).to_str()}\t${compressed_len.to_str()}\t(total=${$total.to_str()})") ? |_| Exit(10)
	Ok({})
}

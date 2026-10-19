app [main!] {
	deflate: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
}

import pf.Stdout
import pf.Path
import pf.Monotonic
import deflate.Deflate

# usage: ctime <original> <params> <out.deflate>
#
# `params` is a two-byte file holding the compression level and the repetition
# count, which is how they arrive rather than as text: converting a command
# line argument to a string currently crashes the Roc compiler.
#
# Verifies the compressed stream decompresses back to the input, writes it out
# so it can be compared against libdeflate's, then times the repetitions and
# prints:  roc\t<min_ns>\t<mbps>\t<compressed_size>
main! = |args| {
	path_os = List.get(args, 1) ? |_| Exit(1)
	params_os = List.get(args, 2) ? |_| Exit(2)
	out_os = List.get(args, 3) ? |_| Exit(3)
	params = Path.read_bytes!(Path.from_os_str(params_os)) ? |_| Exit(4)
	level = (List.get(params, 0) ?? 6).to_u64()
	reps = (List.get(params, 1) ?? 1).to_u64()
	data = Path.read_bytes!(Path.from_os_str(path_os)) ? |_| Exit(5)

	first = match Deflate.compress(data, level) {
		Ok(c) => c
		Err(_) => {
			Stdout.line!("COMPRESS BUG") ? |_| Exit(6)
			return Err(Exit(6))
		}
	}
	back = Deflate.decompress(first) ? |_| Exit(7)
	if back != data {
		Stdout.line!("VERIFY FAIL") ? |_| Exit(8)
		return Err(Exit(8))
	} else {}
	Path.write_bytes!(Path.from_os_str(out_os), first) ? |_| Exit(9)

	in_len = List.len(data)
	compressed_len = List.len(first)
	var $best = 0.U128
	var $total = 0.U64
	var $r = 0.U64
	while $r < reps {
		t0 = Monotonic.now!()
		sz = match Deflate.compress(data, level) {
			Ok(c) => List.len(c)
			Err(_) => 0
		}
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

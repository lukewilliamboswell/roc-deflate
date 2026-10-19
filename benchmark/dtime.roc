app [main!] {
	deflate: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
}

import pf.Stdout
import pf.Path
import pf.Monotonic
import deflate.Deflate

# One decompression into a caller-supplied buffer sized for the whole
# output, mirroring dbench's caller-allocated exact-size buffer.
run_once : List(U8), List(U8) -> U64
run_once = |bytes, buf|
	match Deflate.decompress_into(bytes, buf) {
		Ok(out) => List.len(out)
		Err(CorruptData) => 1
		Err(UnexpectedEnd) => 2
	}

# usage: dtime <stream.deflate> <original> [extra args, one per additional rep]
# Verifies the decompressed stream byte-for-byte against the original, then
# times reps and prints:  roc\t<min_ns>\t<mbps>
main! = |args| {
	reps = List.len(args) - 2
	stream_os = List.get(args, 1) ? |_| Exit(1)
	orig_os = List.get(args, 2) ? |_| Exit(2)
	stream = Path.read_bytes!(Path.from_os_str(stream_os)) ? |_| Exit(3)
	orig = Path.read_bytes!(Path.from_os_str(orig_os)) ? |_| Exit(4)

	first = match Deflate.decompress(stream) {
		Ok(out) => out
		Err(_) => return Err(Exit(5))
	}
	if first != orig {
		Stdout.line!("VERIFY FAIL") ? |_| Exit(6)
		return Err(Exit(7))
	}

	orig_len = List.len(orig)
	var $best = 0.U128
	var $total = 0.U64
	var $r = 0.U64
	while $r < reps {
		# A fresh full-size buffer per rep: the allocator returns the same
		# warm region each time, and the decompressor never grows it. The
		# extra 64 bytes cover the match copy's overrunning word stores,
		# which demand that much spare beyond the final length.
		buf0 = List.with_capacity(orig_len + 64)
		t0 = Monotonic.now!()
		$total = $total + run_once(stream, buf0)
		dt = Monotonic.now!().since(t0).to_nanos().to_u128()
		if $r == 0 or dt < $best {
			$best = dt
		}
		$r = $r + 1
	}
	mbps_x10 = (orig_len.to_u128() * 10_000) // $best
	Stdout.line!("roc\t${$best.to_str()}\t${(mbps_x10 // 10).to_str()}.${(mbps_x10 % 10).to_str()}\t(total=${$total.to_str()})") ? |_| Exit(8)
	Ok({})
}

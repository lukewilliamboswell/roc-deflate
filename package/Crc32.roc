## CRC-32 as gzip uses it (ISO 3309 and ITU-T V.42, the reflected polynomial
## 0xEDB88320), eight bytes per step with slice-by-8 tables, as libdeflate's
## portable `crc32_slice8` does.
##
## This is the package's own, not a dependency: it checks a gzip member's
## output, which can be hundreds of megabytes, and eight bytes a step is about
## five times as fast as a byte at a time under `--opt=speed` (0.12 s against
## 0.6 s for 139 MB on an Apple M-series machine). The harness checks it
## against niclas-ahden/roc-crc32 and real gzip.
Crc32 := [].{

	## Continue a CRC-32 over `len` bytes of `bytes` from `start`, as far as
	## `bytes` goes. A fresh CRC starts from 0, and feeding the bytes in
	## pieces gives the same result as one call over all of them.
	update : U32, List(U8), U64, U64 -> U32
	update = |crc, bytes, start, len| {
		end = start.plus_saturated(len).min(List.len(bytes))
		# The lookups are written out rather than behind a helper, which the
		# dev backend, the default for `roc app.roc`, would call eight times
		# a step: that costs it a quarter more, and LLVM nothing.
		t = tables
		var $crc = crc.bitwise_not()
		var $i = start
		while $i + 8 <= end {
			word = U64.from_le_bytes(bytes, $i) ?? 0
			lo = word.to_u32_wrap().bitwise_xor($crc).to_u64()
			hi = word.shr_zf_wrap(32)
			$crc = (List.get(t, 1792 + lo.bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 1536 + lo.shr_zf_wrap(8).bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 1280 + lo.shr_zf_wrap(16).bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 1024 + lo.shr_zf_wrap(24).bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 768 + hi.bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 512 + hi.shr_zf_wrap(8).bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, 256 + hi.shr_zf_wrap(16).bitwise_and(255)) ?? 0)
				.bitwise_xor(List.get(t, hi.shr_zf_wrap(24).bitwise_and(255)) ?? 0)
			$i = $i + 8
		}
		while $i < end {
			byte = List.get(bytes, $i) ?? 0
			$crc = (List.get(t, $crc.bitwise_xor(byte.to_u32()).bitwise_and(255).to_u64()) ?? 0).bitwise_xor($crc.shr_zf_wrap(8))
			$i = $i + 1
		}
		$crc.bitwise_not()
	}
}

# Eight tables of 256 entries, one after another, so table k starts at
# k * 256. Table 0 is the CRC of each byte value on its own, and table k + 1
# is table k's entry advanced by one more zero byte.
tables : List(U32)
tables = {
	var $t = List.with_capacity(2048)
	var $n = 0.U32
	while $n < 256 {
		var $c = $n
		var $bit = 0
		while $bit < 8 {
			$c = if $c.bitwise_and(1) == 1 { $c.shr_zf_wrap(1).bitwise_xor(0xEDB88320) } else { $c.shr_zf_wrap(1) }
			$bit = $bit + 1
		}
		$t = List.append($t, $c)
		$n = $n + 1
	}
	var $i = 256.U64
	while $i < 2048 {
		prev = List.get($t, $i - 256) ?? 0
		$t = List.append($t, (List.get($t, prev.bitwise_and(255).to_u64()) ?? 0).bitwise_xor(prev.shr_zf_wrap(8)))
		$i = $i + 1
	}
	$t
}

# The check value every CRC-32 catalogue gives, the empty input, and one zero
# byte.
expect Crc32.update(0, "123456789".to_utf8(), 0, 9) == 0xCBF43926

expect Crc32.update(0, [], 0, 0) == 0

expect Crc32.update(0, [0], 0, 1) == 0xD202EF8D

# The eight-byte steps and the byte-at-a-time tail agree wherever the pieces
# split, and a range past the end stops at the end.
expect {
	text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()
	whole = Crc32.update(0, text, 0, List.len(text))
	var $ok = Crc32.update(0, text, 0, U64.highest) == whole
	var $cut = 0.U64
	while $cut <= List.len(text) {
		if Crc32.update(Crc32.update(0, text, 0, $cut), text, $cut, List.len(text)) != whole {
			$ok = False
		} else {}
		$cut = $cut + 1
	}
	$ok
}

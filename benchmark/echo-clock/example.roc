app [main!] {
	deflate: "../../package/main.roc",
	pf: platform "main.roc",
}

import pf.Host exposing [echo!, now!]
import deflate.Deflate
import "../../README.md" as input : List(U8)

main! = |seed| {
	# A runtime level keeps this example's compression from being precomputed.
	level = Deflate.Level.from_u64(1 + seed % 12) ?? 6
	buf = List.with_capacity(Deflate.compress_bound(input.len()))
	start = now!()
	compressed = Deflate.compress_into(input, level, buf)
	elapsed = now!() - start
	decoded = Deflate.decompress(compressed, {}) ?? []
	if decoded != input {
		crash "round-trip failed"
	}
	echo!("${input.len().to_str()} bytes -> ${compressed.len().to_str()} bytes in ${elapsed.to_str()} ns")
}

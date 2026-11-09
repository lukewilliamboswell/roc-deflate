app [target] {
	deflate: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import deflate.Deflate

## Any bytes, decoded under any output bound.
Input := { stream : List(U8), max_output : U64 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			stream: Fuzz.bytes,
			max_output: Fuzz.u64_in(0, max_bound),
		}.Fuzz
	}
}

## Any bytes decode to `Ok` or a named `Err`, never a crash, and the same
## bytes give the same answer twice, and through a fresh `Decoder`.
##
## The bound is exact: when the unbounded decode gives `Ok(bytes)`, the
## bounded one gives the same bytes if they fit and `OutputLimitExceeded` if
## they do not, and when the unbounded decode fails the bounded one fails too.
##
## Memory ratchet, which only ever moves down: the decode holds at most
## `memory_ceiling(max_output)` bytes live beyond what it started with, the
## decode tables plus the output, however hostile the stream. Raising it needs
## a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	# Encoded inputs bypass the generator, so its range is checked here too.
	if input.max_output > max_bound {
		return Fuzz.reject
	}
	bounds : Deflate.Bounds
	bounds = { max_output: input.max_output }
	{ value: bounded, stats } = Fuzz.measure!("decompress-bounded", || Deflate.decompress(input.stream, bounds))
	if stats.peak_live_bytes - stats.entry_live_bytes > memory_ceiling(input.max_output) {
		crash "decompress held more live memory than its bound allows"
	}
	if Deflate.decompress(input.stream, bounds) != bounded {
		crash "decompressing the same bytes twice disagreed"
	}
	if Deflate.decompress_with(Deflate.decoder(), input.stream, bounds).output != bounded {
		crash "decompress_with disagreed with decompress"
	}
	match Deflate.decompress(input.stream, { max_output: U64.highest }) {
		Ok(bytes) => {
			expected = if List.len(bytes) <= input.max_output {
				Ok(bytes)
			} else {
				Err(OutputLimitExceeded)
			}
			if bounded != expected {
				crash "the bounded decode disagreed with the unbounded one"
			}
		}
		Err(_) =>
			if bounded.is_ok() {
				crash "the bounded decode succeeded where the unbounded one failed"
			}
	}
	Fuzz.keep
}

# The largest bound generated. Bounds beyond it are the unbounded decode's.
max_bound : U64
max_bound = 1_048_576

# Measured on nightly-2026-11-07-ad3a5d2 over a 2,101-input corpus: at most
# 12,921 + 3 * max_output. The fixed part is the decoder's state, its decode
# tables, code lengths and counting-sort lists. Without a declared size the
# output starts at three times the input and grows as a list does, and a
# reallocation briefly holds the old buffer and a larger new one.
memory_ceiling : U64 -> U64
memory_ceiling = |max_output| 13_500 + 3 * max_output

text : List(U8)
text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()

target = Fuzz.target_with!({
	name: "inflate-bytes",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || Input.{ stream: [], max_output: 0 } }),
		Fuzz.example({ name: "stored-hello-at-bound", revision: "1", make: || Input.{ stream: [0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], max_output: 5 } }),
		Fuzz.example({ name: "stored-hello-over-bound", revision: "1", make: || Input.{ stream: [0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F], max_output: 4 } }),
		Fuzz.example({ name: "match-before-start", revision: "1", make: || Input.{ stream: [0x03, 0x22, 0x00], max_output: 1_048_576 } }),
		Fuzz.example({ name: "dynamic-one-short", revision: "1", make: || Input.{ stream: Deflate.compress(List.join(List.repeat(text, 40)), 6), max_output: 40 * List.len(text) - 1 } }),
		Fuzz.example({ name: "static-run", revision: "1", make: || Input.{ stream: Deflate.compress(List.repeat(0, 4096), 1), max_output: 1_048_576 } }),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})

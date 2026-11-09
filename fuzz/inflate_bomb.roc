app [target] {
	deflate: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import deflate.Deflate
# `Deflate.compress(List.repeat(0, 8_388_608), 6)`: 8,482 bytes that inflate to
# 8 MiB. tests/harness.roc checks the file is still exactly that stream.
import "bomb.deflate" as bomb : List(U8)

## A bound and a declared size for the bomb.
Input := { max_output : U64, declared : U64 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			max_output: Fuzz.u64_in(0, max_generated),
			declared: Fuzz.u64_in(0, max_generated),
		}.Fuzz
	}
}

## A stream that inflates about 1000:1 stops at its bound: it gives its 8 MiB
## of zeros when they fit and `OutputLimitExceeded` when they do not, under any
## declared size.
##
## Memory ratchets, which only ever move down: the decode holds the tables, the
## reservation `min(declared, max_output)` and, when the declared size is too
## small, the output's growth, and nothing in proportion to what the stream
## asks for beyond the bound. A truthful declared size, or one equal to the
## bound, never reallocates. Raising a ceiling needs a cause recorded in the
## pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	# Encoded inputs bypass the generator, so its ranges are checked here too.
	if input.max_output > max_generated or input.declared > max_generated {
		return Fuzz.reject
	}
	bounds : Deflate.Bounds
	bounds = { max_output: input.max_output, expected_size: Declared(input.declared) }
	{ value: result, stats } = Fuzz.measure!("decompress-bomb", || Deflate.decompress(bomb, bounds))
	expected = if input.max_output >= bomb_size {
		Ok(List.repeat(0, bomb_size))
	} else {
		Err(OutputLimitExceeded)
	}
	if result != expected {
		crash "the bomb did not stop at its bound"
	}
	reserved = input.declared.min(input.max_output)
	written = input.max_output.min(bomb_size)
	live = stats.peak_live_bytes - stats.entry_live_bytes
	if live > fixed_ceiling + reserved.max(growth_factor * written) {
		crash "the bomb held more live memory than its bound and declared size allow"
	}
	if reserved >= written and (stats.reallocs > 0 or live > fixed_ceiling + reserved) {
		crash "a sufficient declared size still reallocated"
	}
	Fuzz.keep
}

bomb_size : U64
bomb_size = 8_388_608

max_generated : U64
max_generated = 16_777_216

# Measured on nightly-2026-11-07-ad3a5d2 over a 220-input corpus: at most
# 12,956 bytes beyond the reservation when it covers the output, with no
# reallocation, and at most 13,041 + 3 * written when it does not, since the
# last reallocation briefly holds the old buffer and a new one larger than
# what the stream goes on to write.
fixed_ceiling : U64
fixed_ceiling = 13_500

growth_factor : U64
growth_factor = 3

example : Str, U64, U64 -> Fuzz.Example(Input)
example = |name, max_output, declared| Fuzz.example({ name, revision: "1", make: || Input.{ max_output, declared } })

target = Fuzz.target_with!({
	name: "inflate-bomb",
	examples: [
		# lukewilliamboswell/roc-deflate#6's acceptance case.
		example("one-mib-declared-one-mib", 1_048_576, 1_048_576),
		example("declared-zero", 16_777_216, 0),
		example("exact-bound-truthful", bomb_size, bomb_size),
		example("one-short", bomb_size - 1, bomb_size),
		example("huge-declared-small-bound", 4_096, 16_777_216),
		example("zero-bound", 0, 0),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})

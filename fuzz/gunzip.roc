app [target] {
	deflate: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import deflate.Deflate
import deflate.Gzip
import Plaintext

## One gzip member: its plaintext and level, the flag byte of its header,
## reserved bits and all, and the optional fields the flags ask for. The name's
## bytes, zeros dropped, are the comment too.
Member : { pieces : List(Plaintext.Piece), level : U64, flags : U8, extra : List(U8), name : List(U8) }

## Members one after another, one byte of them changed, bytes after them, and
## a bound.
Input := { members : List(Member), at : U64, xor : U8, tail : List(U8), max_output : U64 }.{
	parser_for : _
	encoder_for : _

	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			members: Fuzz.list(
				{
					pieces: Fuzz.list({ literal: Fuzz.bytes, back: Fuzz.u64_in(0, 65_535), len: Fuzz.u64_in(0, 1_200) }.Fuzz, 8),
					level: Fuzz.u64_in(0, 12),
					flags: Fuzz.u8,
					extra: Fuzz.bytes,
					name: Fuzz.bytes,
				}.Fuzz,
				4,
			),
			at: Fuzz.u64,
			xor: Fuzz.u8,
			tail: Fuzz.bytes,
			max_output: Fuzz.u64_in(0, max_bound),
		}.Fuzz
	}
}

## Any gzip file built from these parts decodes to `Ok` or a named `Err`,
## never a crash, and the same answer twice. A decode that succeeds gives
## exactly the members' plaintexts one after another: a changed byte either
## fails or lands where nothing is checked (the time, FTEXT, the extra flags,
## the OS, the extra field or the name), never giving other bytes. Bytes after
## the last member never begin with 0x1F, so they are always `TrailingData`
## unless something fails first. Unchanged, with no reserved flag and nothing
## after it, the file gives the plaintexts, cut off exactly at the bound.
##
## The bound is exact, as in `inflate_bytes`: the bounded decode gives the
## unbounded one's bytes when they fit and `OutputLimitExceeded` when they do
## not, and fails whenever the unbounded one fails.
##
## Memory ratchet, which only ever moves down: the decode holds at most
## `memory_ceiling(max_output)` bytes live beyond what it started with,
## however the header, the stream and the trailer are changed. Raising it
## needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	# Encoded inputs bypass the generator, so its ranges are checked here too.
	if input.max_output > max_bound or List.len(input.members) > 4 {
		return Fuzz.reject
	}
	if input.members.any(|m| m.level > 12 or List.len(m.pieces) > 8 or m.pieces.any(|p| p.len > 1_200)) {
		return Fuzz.reject
	}
	plains = input.members.map(|m| Plaintext.expand(m.pieces))
	built = List.join(List.map2(input.members, plains, |m, plain| member(m, plain)))
	edited = if List.is_empty(built) {
		built
	} else {
		at = input.at % List.len(built)
		List.update(built, at, |byte| byte.bitwise_xor(input.xor)) ?? built
	}
	tail = match List.first(input.tail) {
		Ok(0x1F) => input.tail.drop_first(1)
		_ => input.tail
	}
	file = edited.concat(tail)
	all = List.join(plains)

	bounds : Deflate.Bounds
	bounds = { max_output: input.max_output }
	{ value: bounded, stats } = Fuzz.measure!("gunzip-bounded", || Gzip.decompress(file, bounds))
	if stats.peak_live_bytes - stats.entry_live_bytes > memory_ceiling(input.max_output) {
		crash "Gzip.decompress held more live memory than its bound allows"
	}
	if Gzip.decompress(file, bounds) != bounded {
		crash "decompressing the same file twice disagreed"
	}
	unbounded = Gzip.decompress(file, { max_output: U64.highest })
	match unbounded {
		Ok(bytes) => {
			if bytes != all {
				crash "a changed file decoded to other bytes"
			}
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
	clean = input.xor == 0 and List.is_empty(tail) and !List.is_empty(input.members) and input.members.all(|m| m.flags.bitwise_and(0xE0) == 0)
	if clean and unbounded != Ok(all) {
		crash "an unchanged file did not decode to its plaintexts"
	}
	if !List.is_empty(tail) and unbounded.is_ok() {
		crash "bytes after the last member were not TrailingData"
	}
	Fuzz.keep
}

# A member with this header and plaintext. The stream and the trailer are
# `Gzip.compress`'s, which tests/harness.roc holds to libdeflate-gzip byte for
# byte, and the header CRC, when FHCRC asks for one, is computed here.
member : Member, List(U8) -> List(U8)
member = |m, plain| {
	written = Gzip.compress(plain, Deflate.Level.from_u64(m.level) ?? 6)
	body = written.drop_first(10)
	var $header = [0x1F, 0x8B, 8, m.flags, 0, 0, 0, 0, 0, 3]
	if m.flags.bitwise_and(0x04) != 0 {
		extra = List.sublist(m.extra, { start: 0, len: 65_535 })
		len = List.len(extra)
		$header = $header.append(len.to_u8_wrap()).append(len.shr_zf_wrap(8).to_u8_wrap()).concat(extra)
	} else {}
	if m.flags.bitwise_and(0x08) != 0 {
		$header = $header.concat(m.name.drop_if(|b| b == 0)).append(0)
	} else {}
	if m.flags.bitwise_and(0x10) != 0 {
		$header = $header.concat(m.name.drop_if(|b| b == 0)).append(0)
	} else {}
	if m.flags.bitwise_and(0x02) != 0 {
		crc = crc32($header)
		$header = $header.append(crc.to_u8_wrap()).append(crc.shr_zf_wrap(8).to_u8_wrap())
	} else {}
	$header.concat(body)
}

# A byte-at-a-time CRC-32, independent of the package's slice-by-8 one, for
# the header CRC.
crc32 : List(U8) -> U32
crc32 = |bytes| {
	var $crc = 0xFFFFFFFF.U32
	for byte in bytes {
		$crc = $crc.bitwise_xor(byte.to_u32())
		var $bit = 0
		while $bit < 8 {
			$crc = if $crc.bitwise_and(1) == 1 { $crc.shr_zf_wrap(1).bitwise_xor(0xEDB88320) } else { $crc.shr_zf_wrap(1) }
			$bit = $bit + 1
		}
	}
	$crc.bitwise_not()
}

# The largest bound generated. Bounds beyond it are the unbounded decode's.
max_bound : U64
max_bound = 131_072

# Measured on nightly-2026-11-07-ad3a5d2 over a 1,421-input corpus: at most
# 12,959 + 3 * max_output, the raw decoder's own ceiling. The trailer's size
# hint never reserves more than the bound, and the CRC-32 and the header
# allocate nothing.
memory_ceiling : U64 -> U64
memory_ceiling = |max_output| 13_500 + 3 * max_output

text : List(U8)
text = "the cat, the cow, the crow, then the cricket saw the cow again and again".to_utf8()

plain_member : U64, U8 -> Member
plain_member = |level, flags| { pieces: [{ literal: text, back: 30, len: 1_000 }], level, flags, extra: [0x41, 0x42, 0, 0], name: "hello.txt".to_utf8() }

example : Str, List(Member), U64, U8, List(U8), U64 -> Fuzz.Example(Input)
example = |name, members, at, xor, tail, max_output| Fuzz.example({ name, revision: "1", make: || Input.{ members, at, xor, tail, max_output } })

target = Fuzz.target_with!({
	name: "gunzip",
	examples: [
		example("empty", [], 0, 0, [], 0),
		example("one-member", [plain_member(6, 0)], 0, 0, [], max_bound),
		example("every-flag", [plain_member(1, 0x1F)], 0, 0, [], max_bound),
		example("three-members-one-short", [plain_member(0, 0), plain_member(6, 0x08), plain_member(12, 0x1E)], 0, 0, [], 3 * 1_072 - 1),
		example("reserved-flag", [plain_member(6, 0x20)], 0, 0, [], max_bound),
		example("changed-magic", [plain_member(6, 0)], 1, 0x01, [], max_bound),
		example("changed-to-fhcrc", [plain_member(6, 0)], 3, 0x02, [], max_bound),
		example("changed-second-member", [plain_member(6, 0), plain_member(1, 0)], 900, 0x40, [], max_bound),
		example("trailing-zeros", [plain_member(6, 0)], 0, 0, [0, 0, 0, 0], max_bound),
	],
	generator: Input.generator_for(Default),
	test!,
	show: |input| Str.inspect(input),
})

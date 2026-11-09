import DeflateTables

## DEFLATE decompression, ported from libdeflate's `deflate_decompress.c` and
## `decompress_template.h`.
##
## The shape follows libdeflate rather than a textbook inflate: Huffman symbols
## are decoded with a first-level table indexed by the next `table_bits` input
## bits (plus one level of subtables for the rare longer codewords), and the
## bitstream is kept in a 64-bit buffer refilled eight bytes at a time. Each
## decode table entry packs everything a decode step needs (symbol or base
## value, codeword length, and extra-bit count), so the hot loop is a table
## load, a shift, and a subtract, instead of a walk over code lengths one bit
## at a time.
Inflate := [].{

	## The working state one stream's decode needs, kept between streams so a
	## caller decoding many can allocate it once, as libdeflate's
	## `libdeflate_alloc_decompressor` does.
	##
	## The litlen and offset decode tables are rebuilt for every dynamic block
	## but into the same allocations, and so are the precode table and the
	## two counting-sort lists a table build reads before it writes. The lists
	## a build needs zeroed, the code lengths and the length counts, are taken
	## fresh: a zeroed allocation is cheaper than clearing a reused list. Rebuilding writes every entry a decode can read,
	## so leftover entries never need clearing. `static_loaded` says the
	## litlen and offset tables still hold the static Huffman codes, as they do
	## after a static block until a dynamic one overwrites them, so a run of
	## static blocks builds them once, even across streams. libdeflate keeps
	## the same flag.
	Scratch : {
		litlen : List(U32),
		offset : List(U32),
		precode : List(U32),
		offsets : List(U64),
		sorted : List(U16),
		static_loaded : Bool,
		static_litlen_mask : U64,
	}

	## Fresh working state, holding no tables yet.
	new_scratch : () -> Scratch
	new_scratch = || {
		litlen: List.repeat(0.U32, Inflate.litlen_enough),
		offset: List.repeat(0.U32, Inflate.offset_enough),
		precode: List.repeat(0.U32, Inflate.precode_enough),
		offsets: [],
		sorted: [],
		static_loaded: False,
		static_litlen_mask: 0,
	}

	## Decompress a raw DEFLATE stream, appending the output to `out`, and
	## hand back the working state for the next stream.
	##
	## Mirrors `libdeflate_deflate_decompress`'s generic loop. Input past the
	## final block is ignored, matching a stream embedded in a larger buffer.
	##
	## The stream may append at most `max_output` bytes to `out`. Decoding
	## stops with `OutputLimitExceeded` before any append that would pass it,
	## so the output never holds more than `max_output` bytes past what `out`
	## held. Before decoding, `reserve` more bytes of capacity are reserved
	## past `out`'s length, never more than `max_output`, plus the
	## `copy_scratch` a match copy needs, so a truthful size never
	## reallocates.
	##
	## The bytes already in `out` are not part of the stream, so a match that
	## reaches back past the stream's own output is corrupt, just as it is
	## when `out` starts empty.
	##
	## A failed decode may have overwritten the tables partway, so it hands
	## back fresh state instead.
	inflate : Scratch, List(U8), List(U8), U64, U64 -> { scratch : Scratch, output : Try(List(U8), [CorruptData, UnexpectedEnd, OutputLimitExceeded]) }
	inflate = |scratch, input, out, max_output, reserve| {
		# The reservation and the match-copy scratch past it.
		reserved = if reserve == 0 or max_output == 0 { out } else { List.reserve(out, reserve.min(max_output).plus_saturated(Inflate.copy_scratch)) }
		match Inflate.inflate_stream(scratch, input, reserved, max_output) {
			Ok(done) => { scratch: done.scratch, output: Ok(done.out) }
			Err(err) => { scratch: Inflate.new_scratch(), output: Err(err) }
		}
	}

	inflate_stream : Scratch, List(U8), List(U8), U64 -> Try({ scratch : Scratch, out : List(U8) }, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	inflate_stream = |scratch, input, out, max_output| {
		in_len = List.len(input)
		out_start = List.len(out)
		# The most bytes the output may hold, which no list length reaches
		# when the bound is larger than anything addressable.
		out_limit = if max_output > U64.highest - out_start {
			U64.highest
		} else {
			out_start + max_output
		}

		var $out = out
		var $in_next = 0.U64
		var $bitbuf = 0.U64
		var $bitsleft = 0.U64
		var $overread = 0.U64
		var $more_blocks = True

		# The tables round-trip through read_dynamic_header,
		# build_block_tables and inflate_block back here.
		var $litlen_scratch = scratch.litlen
		var $offset_scratch = scratch.offset
		var $precode_scratch = scratch.precode
		var $offsets = scratch.offsets
		var $sorted = scratch.sorted
		var $static_loaded = scratch.static_loaded
		var $static_litlen_mask = scratch.static_litlen_mask

		while $more_blocks {
			r0 = Inflate.refill(input, $in_next, $bitbuf, $bitsleft, $overread)?
			$in_next = r0.in_next
			$bitbuf = r0.bitbuf
			$bitsleft = r0.bitsleft
			$overread = r0.overread

			$more_blocks = $bitbuf.bitwise_and(1) == 0
			block_type = $bitbuf.shr_zf_wrap(1).bitwise_and(3)

			if block_type == 0 {
				# Stored block: realign to the byte after the header, then
				# copy LEN raw bytes. Any refilled-but-unconsumed whole
				# bytes are returned to the input cursor first. If the header
				# itself came from the implicit zero bytes, the input ended
				# before the block did.
				$bitsleft = $bitsleft - 3
				unread = $bitsleft.shr_zf_wrap(3)
				if $overread > unread {
					return Err(UnexpectedEnd)
				} else {}
				$in_next = $in_next - (unread - $overread)
				$overread = 0
				$bitbuf = 0
				$bitsleft = 0

				if in_len < $in_next + 4 {
					return Err(UnexpectedEnd)
				} else {}
				len_lo = List.get(input, $in_next) ?? 0
				len_hi = List.get(input, $in_next + 1) ?? 0
				nlen_lo = List.get(input, $in_next + 2) ?? 0
				nlen_hi = List.get(input, $in_next + 3) ?? 0
				len = len_lo.to_u64() + len_hi.to_u64().shl_wrap(8)
				nlen = nlen_lo.to_u64() + nlen_hi.to_u64().shl_wrap(8)
				if len + nlen != 0xFFFF {
					return Err(CorruptData)
				} else {}
				$in_next = $in_next + 4
				if in_len < $in_next + len {
					return Err(UnexpectedEnd)
				} else {}
				if len > out_limit - List.len($out) {
					return Err(OutputLimitExceeded)
				} else {}
				$out = List.append_sublist($out, input, { start: $in_next, len })
				$in_next = $in_next + len
			} else if block_type <= 2 {
				tables =
					if block_type == 2 {
						# Dynamic Huffman block: read the header and the
						# run-length-encoded codeword lengths.
						# Destructured, so each list moves out of the header and
						# the build below is the only holder of the ones it
						# mutates. Read through the record, they stay shared
						# with it, and the build copies them.
						{ in_next: h_in_next, bitbuf: h_bitbuf, bitsleft: h_bitsleft, overread: h_overread, lens: h_lens, num_litlen_syms, num_offset_syms, precode: h_precode, offsets: h_offsets, sorted: h_sorted } = Inflate.read_dynamic_header(input, $in_next, $bitbuf, $bitsleft, $overread, $precode_scratch, $offsets, $sorted)?
						$in_next = h_in_next
						$bitbuf = h_bitbuf
						$bitsleft = h_bitsleft
						$overread = h_overread
						$precode_scratch = h_precode
						$static_loaded = False
						built = Inflate.build_block_tables(h_lens, num_litlen_syms, num_offset_syms, $litlen_scratch, $offset_scratch, h_offsets, h_sorted) ? |_| Inflate.bad_data(h_bitsleft, h_overread)
						$offsets = built.offsets
						$sorted = built.sorted
						{ litlen: built.litlen, litlen_mask: built.litlen_mask, offset: built.offset }
					} else {
						# Static Huffman block, built only when a dynamic block
						# has overwritten the tables since the last one.
						$bitbuf = $bitbuf.shr_zf_wrap(3)
						$bitsleft = $bitsleft - 3
						if $static_loaded {
							{ litlen: $litlen_scratch, litlen_mask: $static_litlen_mask, offset: $offset_scratch }
						} else {
							built = Inflate.build_block_tables(Inflate.static_lens, 288, 32, $litlen_scratch, $offset_scratch, $offsets, $sorted)?
							$static_loaded = True
							$static_litlen_mask = built.litlen_mask
							$offsets = built.offsets
							$sorted = built.sorted
							{ litlen: built.litlen, litlen_mask: built.litlen_mask, offset: built.offset }
						}
					}

				decoded = Inflate.inflate_block(input, $in_next, $bitbuf, $bitsleft, $overread, $out, out_start, out_limit, tables)?
				$in_next = decoded.in_next
				$bitbuf = decoded.bitbuf
				$bitsleft = decoded.bitsleft
				$overread = decoded.overread
				$out = decoded.out
				$litlen_scratch = decoded.litlen
				$offset_scratch = decoded.offset
			} else {
				return Err(CorruptData)
			}
		}

		# Consuming any of the implicit appended zero bytes means the stream
		# was truncated.
		if $overread > $bitsleft.shr_zf_wrap(3) {
			Err(UnexpectedEnd)
		} else {
			Ok({
				scratch: {
					litlen: $litlen_scratch,
					offset: $offset_scratch,
					precode: $precode_scratch,
					offsets: $offsets,
					sorted: $sorted,
					static_loaded: $static_loaded,
					static_litlen_mask: $static_litlen_mask,
				},
				out: $out,
			})
		}
	}

	# --- Input bitstream ---
	#
	# `bitbuf` holds unconsumed bits with the next bit at bit 0, and `bitsleft`
	# counts them. A refill loads eight input bytes at once when they exist
	# (`U64.from_le_bytes` and shifting by the current fill, advancing the
	# cursor by however many whole bytes fit), and falls back to byte-at-a-time
	# near the end of input, appending implicit zero bytes and counting them in
	# `overread` so truncation is detected when those zeros would be consumed.
	# After either refill at least 56 bits are available.

	RefillState : { in_next : U64, bitbuf : U64, bitsleft : U64, overread : U64 }

	## The error for output that would pass the limit, with the bitstream in
	## this state. Output decoded from the implicit zero bytes is not really
	## there, so then the input ended before the stream did.
	over_limit : U64, U64 -> [OutputLimitExceeded, UnexpectedEnd]
	over_limit = |bitsleft, overread|
		if overread > bitsleft.bitwise_and(255).shr_zf_wrap(3) {
			UnexpectedEnd
		} else {
			OutputLimitExceeded
		}

	## The spare capacity `List.append_range_within` needs past the bytes it
	## appends, since its copies store whole words that overshoot the range
	## (`append_range_within_scratch_bytes` in the compiler's `list.zig`). With
	## less spare it reallocates, however much room the range has, so a
	## reservation for a known output size includes it.
	copy_scratch : U64
	copy_scratch = 40

	## The most bytes one fast-loop iteration appends: two literals and then
	## the longest match, or three literals.
	fast_loop_max_output : U64
	fast_loop_max_output = 2 + DeflateTables.max_match_len

	## The error for a check that failed with the bitstream in this state.
	## A failure after any of the implicit zero bytes were consumed means the
	## input ended before the stream did, whatever the zeros happened to
	## decode as, so only a failure on real input bits is corrupt data.
	bad_data : U64, U64 -> [CorruptData, UnexpectedEnd, OutputLimitExceeded]
	bad_data = |bitsleft, overread|
		if overread > bitsleft.bitwise_and(255).shr_zf_wrap(3) {
			UnexpectedEnd
		} else {
			CorruptData
		}

	refill : List(U8), U64, U64, U64, U64 -> Try(RefillState, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	refill = |input, in_next, bitbuf, bitsleft_raw, overread| {
		# Consumes subtract whole decode entries from `bitsleft`, so only its
		# low byte is meaningful. Recover the exact count once here.
		bitsleft = bitsleft_raw.bitwise_and(255)
		if List.len(input) - in_next.min(List.len(input)) >= 8 {
			word = U64.from_le_bytes(input, in_next) ?? 0
			Ok({
				in_next: in_next + 7 - bitsleft.shr_zf_wrap(3).bitwise_and(7),
				bitbuf: bitbuf.bitwise_or(word.shl_wrap(bitsleft.to_u8_wrap())),
				bitsleft: bitsleft.bitwise_or(56),
				overread,
			})
		} else {
			var $bitbuf2 = bitbuf
			var $bitsleft2 = bitsleft
			var $in_next2 = in_next
			var $overread2 = overread
			while $bitsleft2 < 56 {
				match List.get(input, $in_next2) {
					Ok(byte) => {
						$bitbuf2 = $bitbuf2.bitwise_or(byte.to_u64().shl_wrap($bitsleft2.to_u8_wrap()))
						$in_next2 = $in_next2 + 1
					}
					Err(_) => {
						$overread2 = $overread2 + 1
						if $overread2 > 8 {
							return Err(UnexpectedEnd)
						} else {}
					}
				}
				$bitsleft2 = $bitsleft2 + 8
			}
			Ok({ in_next: $in_next2, bitbuf: $bitbuf2, bitsleft: $bitsleft2, overread: $overread2 })
		}
	}

	# --- Decode table entry format (from libdeflate) ---
	#
	# Litlen table entries:
	#   literal:          bit 31 set, literal value in bits 23-16
	#   length:           length base in bits 24-16, codeword length in bits
	#                     11-8, codeword length + extra bits in bits 4-0
	#   end of block:     bits 15 and 13 set
	#   subtable pointer: bits 15 and 14 set, subtable start in bits 30-16,
	#                     subtable bits in 11-8, main table bits in 3-0
	# Offset table entries are lengths/subtable pointers with the offset base
	# in bits 31-16. Precode entries hold the presymbol in bits 20-16. In every
	# entry the low byte is the total bit count the entry consumes.

	huffdec_literal : U32
	huffdec_literal = 0x80000000

	huffdec_exceptional : U32
	huffdec_exceptional = 0x8000

	huffdec_subtable_pointer : U32
	huffdec_subtable_pointer = 0x4000

	huffdec_end_of_block : U32
	huffdec_end_of_block = 0x2000

	precode_tablebits : U64
	precode_tablebits = 7

	precode_enough : U64
	precode_enough = 128

	litlen_tablebits : U64
	litlen_tablebits = 11

	litlen_enough : U64
	litlen_enough = 2342

	offset_tablebits : U64
	offset_tablebits = 8

	offset_enough : U64
	offset_enough = 402

	## The longest codeword any DEFLATE code has.
	max_codeword_len : U64
	max_codeword_len = 15

	## The most symbols any DEFLATE code has: the litlen code's 288.
	max_num_syms : U64
	max_num_syms = 288

	## A list of `n` elements whose contents do not matter beyond a zero
	## first element, reusing `list` when it already has that length. That
	## covers the offsets, whose first entry counts up from zero while every
	## other entry a build reads it writes first, and the sorted symbols, every
	## one of which a build writes before reading. Writing the first element
	## also consumes the reused list: handed back as it stands it would be a
	## borrowed parameter, which the build's first write would copy.
	reused_u64 : List(U64), U64 -> List(U64)
	reused_u64 = |list, n|
		if List.len(list) == n {
			match List.set(list, 0, 0) {
				Ok(set_list) => set_list
				Err(_) => crash "Inflate.reused_u64: the length was checked"
			}
		} else {
			List.repeat(0, n)
		}

	## `reused_u64` for a list of `U16`.
	reused_u16 : List(U16), U64 -> List(U16)
	reused_u16 = |list, n|
		if List.len(list) == n {
			match List.set(list, 0, 0) {
				Ok(set_list) => set_list
				Err(_) => crash "Inflate.reused_u16: the length was checked"
			}
		} else {
			List.repeat(0, n)
		}

	## Room for every litlen and offset code length, plus the worst-case
	## overrun of a repeat that runs past the total.
	lens_enough : U64
	lens_enough = 288 + 32 + 137

	## The static decode-result half of each precode table entry.
	precode_decode_results : List(U32)
	precode_decode_results = {
		var $results = List.with_capacity(19.U64)
		var $sym = 0.U32
		while $sym < 19 {
			$results = List.append($results, $sym.shl_wrap(16))
			$sym = $sym + 1
		}
		$results
	}

	## The static decode-result half of each litlen table entry: 256 literals,
	## end-of-block, then the 29 length slots (the last one repeated for the
	## two reserved symbols, as libdeflate does).
	litlen_decode_results : List(U32)
	litlen_decode_results = {
		var $results = List.with_capacity(288.U64)
		var $lit = 0.U32
		while $lit < 256 {
			$results = List.append($results, Inflate.huffdec_literal.bitwise_or($lit.shl_wrap(16)))
			$lit = $lit + 1
		}
		$results = List.append($results, Inflate.huffdec_exceptional.bitwise_or(Inflate.huffdec_end_of_block))
		bases = DeflateTables.length_slot_base
		extras = DeflateTables.extra_length_bits
		var $slot = 0.U64
		while $slot < 29 {
			base = List.get(bases, $slot) ?? 0
			extra = (List.get(extras, $slot) ?? 0).to_u32()
			$results = List.append($results, base.shl_wrap(16).bitwise_or(extra))
			$slot = $slot + 1
		}
		last = List.get($results, 285.U64) ?? 0
		$results.append(last).append(last)
	}

	## The static decode-result half of each offset table entry: the 30 offset
	## slots, the last repeated for the two reserved symbols.
	offset_decode_results : List(U32)
	offset_decode_results = {
		bases = DeflateTables.offset_slot_base
		extras = DeflateTables.extra_offset_bits
		var $results = List.with_capacity(32.U64)
		var $slot = 0.U64
		while $slot < 30 {
			base = List.get(bases, $slot) ?? 0
			extra = (List.get(extras, $slot) ?? 0).to_u32()
			$results = List.append($results, base.shl_wrap(16).bitwise_or(extra))
			$slot = $slot + 1
		}
		last = List.get($results, 29.U64) ?? 0
		$results.append(last).append(last)
	}

	## Combine a symbol's static decode result with its remaining codeword
	## length. Mirrors `make_decode_table_entry`.
	make_entry : List(U32), U64, U32 -> U32
	make_entry = |decode_results, sym, len|
		(List.get(decode_results, sym) ?? 0) + len.shl_wrap(8) + len

	BuiltTable : { table : List(U32), table_bits : U64, offsets : List(U64), sorted : List(U16) }

	## Build a decode table for one canonical Huffman code from its codeword
	## lengths. Ported from `build_decode_table`. See that function for the
	## details of subtable layout and the incremental table-doubling fill.
	##
	## When `dynamic_table_bits` is set, `table_bits` is treated as a maximum
	## and reduced to the longest codeword length actually used (libdeflate
	## does this for the litlen table only).
	##
	## `scratch` supplies the table's backing storage, sized `enough` for the
	## code by its caller. Every entry a decode can reach is written before
	## the table is returned, so a previous block's table can be passed back
	## in as it stands. `offsets` and `sorted` are a previous build's
	## counting-sort lists, handed back for the next one, since a build writes
	## every entry of them it reads.
	build_decode_table : List(U8), U64, List(U32), U64, U64, Bool, List(U32), List(U64), List(U16) -> Try(BuiltTable, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	build_decode_table = |lens, num_syms, decode_results, max_table_bits, max_codeword_len_limit, dynamic_table_bits, scratch, offsets0, sorted0| {
		# The per-symbol loops below index `lens` by every symbol under
		# `num_syms` and the per-length tables by codeword lengths up to
		# `max_codeword_len_limit`. Bounding everything once up front keeps
		# each loop's element accesses in bounds.
		if List.len(lens) < num_syms {
			return Err(CorruptData)
		} else {}
		# Count codewords of each length, including length 0.
		var $len_counts = List.repeat(0.U64, Inflate.max_codeword_len + 1)
		if List.len($len_counts) <= max_codeword_len_limit {
			return Err(CorruptData)
		} else {}
		var $sym = 0.U64
		while $sym < num_syms {
			len = (List.get(lens, $sym) ?? 0).to_u64()
			if len > max_codeword_len_limit {
				return Err(CorruptData)
			} else {}
			len_count = (List.get($len_counts, len) ?? 0) + 1
			$len_counts = match List.set($len_counts, len, len_count) {
				Ok(set_len_counts) => set_len_counts
				Err(_) => return Err(CorruptData)
			}
			$sym = $sym + 1
		}

		var $max_codeword_len = max_codeword_len_limit
		while $max_codeword_len > 1 and (List.get($len_counts, $max_codeword_len) ?? 0) == 0 {
			$max_codeword_len = $max_codeword_len - 1
		}
		table_bits = if dynamic_table_bits {
			max_table_bits.min($max_codeword_len)
		} else {
			max_table_bits
		}

		# Sort symbols by codeword length, then symbol value, via a counting
		# sort, computing the used codespace in the same pass. The offsets
		# table is sized by the length limit so any guarded length indexes it
		# in bounds. Entries past the trimmed maximum stay zero and unread.
		var $offsets = Inflate.reused_u64(offsets0, Inflate.max_codeword_len + 2)
		if List.len($offsets) <= max_codeword_len_limit {
			return Err(CorruptData)
		} else {}
		$offsets = match List.set($offsets, 1, List.get($len_counts, 0) ?? 0) {
			Ok(set_offsets) => set_offsets
			Err(_) => return Err(CorruptData)
		}
		var $codespace_used = 0.U64
		var $len = 1.U64
		while $len < $max_codeword_len {
			prev = List.get($offsets, $len) ?? 0
			count = List.get($len_counts, $len) ?? 0
			$offsets = match List.set($offsets, $len + 1, prev + count) {
				Ok(set_offsets) => set_offsets
				Err(_) => return Err(CorruptData)
			}
			$codespace_used = $codespace_used.shl_wrap(1) + count
			$len = $len + 1
		}
		$codespace_used = $codespace_used.shl_wrap(1) + (List.get($len_counts, $max_codeword_len) ?? 0)

		var $sorted_syms = Inflate.reused_u16(sorted0, Inflate.max_num_syms)
		$sym = 0
		while $sym < num_syms {
			len = (List.get(lens, $sym) ?? 0).to_u64()
			if len > max_codeword_len_limit {
				return Err(CorruptData)
			} else {}
			slot = List.get($offsets, len) ?? 0
			$sorted_syms = match List.set($sorted_syms, slot, $sym.to_u16_wrap()) {
				Ok(set_sorted_syms) => set_sorted_syms
				Err(_) => return Err(CorruptData)
			}
			$offsets = match List.set($offsets, len, slot + 1) {
				Ok(set_offsets) => set_offsets
				Err(_) => return Err(CorruptData)
			}
			$sym = $sym + 1
		}
		# Index of the first used symbol. Everything before it has length 0.
		first_used = (List.get($offsets, 0) ?? 0)

		full = 1.U64.shl_wrap($max_codeword_len.to_u8_wrap())
		if $codespace_used > full {
			return Err(CorruptData)
		} else {}

		if $codespace_used < full {
			# An incomplete code is allowed only when empty or when it has a
			# single codeword of length 1. Either maps to a complete
			# one-symbol code so the decoder needs no error entries.
			single_sym =
				if $codespace_used == 0 {
					0.U64
				} else {
					if $codespace_used != 1.U64.shl_wrap(($max_codeword_len - 1).to_u8_wrap()) or (List.get($len_counts, 1) ?? 0) != 1 {
						return Err(CorruptData)
					} else {}
					(List.get($sorted_syms, first_used) ?? 0).to_u64()
				}
			entry = Inflate.make_entry(decode_results, single_sym, 1)
			var $table0 = scratch
			var $i = 0.U64
			table_len = 1.U64.shl_wrap(table_bits.to_u8_wrap())
			while $i < table_len {
				$table0 = match List.set($table0, $i, entry) {
					Ok(set_table0) => set_table0
					Err(_) => return Err(CorruptData)
				}
				$i = $i + 1
			}
			return Ok({ table: $table0, table_bits, offsets: $offsets, sorted: $sorted_syms })
		} else {}

		# The code is complete: enumerate codewords in lexicographic order,
		# filling direct entries with incremental table doubling, then the
		# subtables for codewords longer than `table_bits`.
		var $table = scratch
		var $sorted_index = first_used
		var $codeword = 0.U64
		$len = 1
		var $count = 0.U64
		while (List.get($len_counts, $len) ?? 0) == 0 {
			$len = $len + 1
		}
		$count = List.get($len_counts, $len) ?? 0
		var $cur_table_end = 1.U64.shl_wrap($len.to_u8_wrap())

		var $filling_direct = True
		while $filling_direct and $len <= table_bits {
			# All `count` codewords with length `len` bits.
			while $count > 0 {
				sym2 = (List.get($sorted_syms, $sorted_index) ?? 0).to_u64()
				$sorted_index = $sorted_index + 1
				$table = match List.set($table, $codeword, Inflate.make_entry(decode_results, sym2, $len.to_u32_wrap())) {
					Ok(set_table) => set_table
					Err(_) => return Err(CorruptData)
				}

				if $codeword == $cur_table_end - 1 {
					# Last codeword (all ones): finish doubling out to the
					# full table size.
					while $len < table_bits {
						$table = match List.copy_range_within($table, $cur_table_end, 0, $cur_table_end) {
							Ok(doubled_table) => doubled_table
							Err(_) => return Err(CorruptData)
						}
						$cur_table_end = $cur_table_end.shl_wrap(1)
						$len = $len + 1
					}
					return Ok({ table: $table, table_bits, offsets: $offsets, sorted: $sorted_syms })
				} else {}

				# Advance to the lexicographically next bit-reversed codeword.
				flipped = $codeword.bitwise_xor($cur_table_end - 1).to_u32_wrap()
				bit_index = 31 - U32.count_leading_zero_bits(flipped)
				bit = 1.U64.shl_wrap(bit_index.to_u8_wrap())
				$codeword = $codeword.bitwise_and(bit - 1).bitwise_or(bit)
				$count = $count - 1
			}
			# Advance to the next codeword length, doubling the table.
			var $advancing = True
			while $advancing {
				$len = $len + 1
				if $len <= table_bits {
					$table = match List.copy_range_within($table, $cur_table_end, 0, $cur_table_end) {
						Ok(doubled_table) => doubled_table
						Err(_) => return Err(CorruptData)
					}
					$cur_table_end = $cur_table_end.shl_wrap(1)
				} else {}
				$count = List.get($len_counts, $len) ?? 0
				if $count != 0 or $len > $max_codeword_len {
					$advancing = False
				} else {}
			}
			if $len > table_bits {
				$filling_direct = False
			} else {}
		}

		# Codewords longer than `table_bits` go through subtables.
		$cur_table_end = 1.U64.shl_wrap(table_bits.to_u8_wrap())
		var $subtable_prefix = 0xFFFFFFFF.U64
		var $subtable_start = 0.U64
		table_mask = 1.U64.shl_wrap(table_bits.to_u8_wrap()) - 1
		while True {
			if $codeword.bitwise_and(table_mask) != $subtable_prefix {
				$subtable_prefix = $codeword.bitwise_and(table_mask)
				$subtable_start = $cur_table_end
				# Subtable length: long enough that the remaining codewords
				# can fill it exactly.
				var $subtable_bits = $len - table_bits
				var $codespace = $count
				while $codespace < 1.U64.shl_wrap($subtable_bits.to_u8_wrap()) {
					$subtable_bits = $subtable_bits + 1
					$codespace = $codespace.shl_wrap(1) + (List.get($len_counts, table_bits + $subtable_bits) ?? 0)
				}
				$cur_table_end = $subtable_start + 1.U64.shl_wrap($subtable_bits.to_u8_wrap())

				pointer = $subtable_start.to_u32_wrap().shl_wrap(16)
					.bitwise_or(Inflate.huffdec_exceptional)
					.bitwise_or(Inflate.huffdec_subtable_pointer)
					.bitwise_or($subtable_bits.to_u32_wrap().shl_wrap(8))
					.bitwise_or(table_bits.to_u32_wrap())
				$table = match List.set($table, $subtable_prefix, pointer) {
					Ok(set_table) => set_table
					Err(_) => return Err(CorruptData)
				}
			} else {}

			sym3 = (List.get($sorted_syms, $sorted_index) ?? 0).to_u64()
			$sorted_index = $sorted_index + 1
			entry = Inflate.make_entry(decode_results, sym3, ($len - table_bits).to_u32_wrap())
			var $i2 = $subtable_start + $codeword.shr_zf_wrap(table_bits.to_u8_wrap())
			stride = 1.U64.shl_wrap(($len - table_bits).to_u8_wrap())
			while $i2 < $cur_table_end {
				$table = match List.set($table, $i2, entry) {
					Ok(set_table) => set_table
					Err(_) => return Err(CorruptData)
				}
				$i2 = $i2 + stride
			}

			if $codeword == 1.U64.shl_wrap($len.to_u8_wrap()) - 1 {
				return Ok({ table: $table, table_bits, offsets: $offsets, sorted: $sorted_syms })
			} else {}
			flipped2 = $codeword.bitwise_xor(1.U64.shl_wrap($len.to_u8_wrap()) - 1).to_u32_wrap()
			bit_index2 = 31 - U32.count_leading_zero_bits(flipped2)
			bit2 = 1.U64.shl_wrap(bit_index2.to_u8_wrap())
			$codeword = $codeword.bitwise_and(bit2 - 1).bitwise_or(bit2)
			$count = $count - 1
			while $count == 0 {
				$len = $len + 1
				$count = List.get($len_counts, $len) ?? 0
			}
		}
	}

	BlockTables : { litlen : List(U32), litlen_mask : U64, offset : List(U32) }

	## The fixed code lengths of RFC 1951 section 3.2.6, which every static
	## Huffman block uses.
	static_lens : List(U8)
	static_lens = List.repeat(8.U8, 144)
		.concat(List.repeat(9.U8, 112))
		.concat(List.repeat(7.U8, 24))
		.concat(List.repeat(8.U8, 8))
		.concat(List.repeat(5.U8, 32))

	## Build the litlen and offset decode tables for one block's code lengths,
	## where `lens` holds the litlen lengths followed by the offset lengths.
	## The scratch lists supply the tables' backing storage, and the
	## decode-result halves are built once per stream by the caller.
	BuiltBlock : { litlen : List(U32), litlen_mask : U64, offset : List(U32), offsets : List(U64), sorted : List(U16) }

	build_block_tables : List(U8), U64, U64, List(U32), List(U32), List(U64), List(U16) -> Try(BuiltBlock, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	build_block_tables = |lens, num_litlen_syms, num_offset_syms, litlen_scratch, offset_scratch, offsets, sorted| {
		offset_lens = List.sublist(lens, { start: num_litlen_syms, len: num_offset_syms })
		# Destructured, so the counting lists move on to the litlen build
		# rather than staying shared with this record, which would copy them.
		{ table: offset_table, table_bits: _, offsets: offset_offsets, sorted: offset_sorted } = Inflate.build_decode_table(
			offset_lens,
			num_offset_syms,
			Inflate.offset_decode_results,
			Inflate.offset_tablebits,
			15,
			False,
			offset_scratch,
			offsets,
			sorted,
		)?
		litlen_built = Inflate.build_decode_table(
			List.sublist(lens, { start: 0, len: num_litlen_syms }),
			num_litlen_syms,
			Inflate.litlen_decode_results,
			Inflate.litlen_tablebits,
			15,
			True,
			litlen_scratch,
			offset_offsets,
			offset_sorted,
		)?
		Ok({
			litlen: litlen_built.table,
			litlen_mask: 1.U64.shl_wrap(litlen_built.table_bits.to_u8_wrap()) - 1,
			offset: offset_table,
			offsets: litlen_built.offsets,
			sorted: litlen_built.sorted,
		})
	}

	DynamicHeader : {
		in_next : U64,
		bitbuf : U64,
		bitsleft : U64,
		overread : U64,
		lens : List(U8),
		num_litlen_syms : U64,
		num_offset_syms : U64,
		precode : List(U32),
		offsets : List(U64),
		sorted : List(U16),
	}

	## The order precode codeword lengths are stored in.
	precode_lens_permutation : List(U8)
	precode_lens_permutation = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

	## Read a dynamic Huffman block's header: the counts, the precode, and the
	## run-length-encoded litlen and offset codeword lengths.
	##
	## On entry the bitbuffer still holds BFINAL and BTYPE. They are consumed
	## here together with the counts, exactly as in the template.
	read_dynamic_header : List(U8), U64, U64, U64, U64, List(U32), List(U64), List(U16) -> Try(DynamicHeader, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	read_dynamic_header = |input, in_next0, bitbuf0, bitsleft0, overread0, precode_scratch, offsets, sorted| {
		num_litlen_syms = 257 + bitbuf0.shr_zf_wrap(3).bitwise_and(31)
		num_offset_syms = 1 + bitbuf0.shr_zf_wrap(8).bitwise_and(31)
		num_explicit_precode_lens = 4 + bitbuf0.shr_zf_wrap(13).bitwise_and(15)

		# A 64-bit refill holds 18 three-bit precode lengths, one short of the
		# maximum 19, so the first length is taken from the header refill.
		var $precode_lens = List.repeat(0.U8, 19)
		first_slot = (List.get(Inflate.precode_lens_permutation, 0) ?? 0).to_u64()
		$precode_lens = match List.set($precode_lens, first_slot, bitbuf0.shr_zf_wrap(17).bitwise_and(7).to_u8_wrap()) {
			Ok(set_precode_lens) => set_precode_lens
			Err(_) => return Err(CorruptData)
		}

		r1 = Inflate.refill(input, in_next0, bitbuf0.shr_zf_wrap(20), bitsleft0 - 20, overread0)?
		var $in_next = r1.in_next
		var $bitbuf = r1.bitbuf
		var $bitsleft = r1.bitsleft
		var $overread = r1.overread

		var $i = 1.U64
		while $i < num_explicit_precode_lens {
			slot = (List.get(Inflate.precode_lens_permutation, $i) ?? 0).to_u64()
			$precode_lens = match List.set($precode_lens, slot, $bitbuf.bitwise_and(7).to_u8_wrap()) {
				Ok(set_precode_lens) => set_precode_lens
				Err(_) => return Err(CorruptData)
			}
			$bitbuf = $bitbuf.shr_zf_wrap(3)
			$bitsleft = $bitsleft - 3
			$i = $i + 1
		}

		precode_built = Inflate.build_decode_table(
			$precode_lens,
			19,
			Inflate.precode_decode_results,
			Inflate.precode_tablebits,
			7,
			False,
			precode_scratch,
			offsets,
			sorted,
		) ? |_| Inflate.bad_data($bitsleft, $overread)
		precode_table = precode_built.table
		# Every precode lookup below masks with 127, so bounding the table
		# once keeps the per-symbol reads in bounds.
		if List.len(precode_table) <= 127 {
			return Err(CorruptData)
		} else {}

		# Decode the litlen and offset codeword lengths. The lens list has
		# slack for the worst-case repeat overrun (137 extra), so repeats can
		# be written before the total is range-checked.
		num_lens = num_litlen_syms + num_offset_syms
		var $lens = List.repeat(0.U8, Inflate.lens_enough)
		var $n = 0.U64
		while $n < num_lens {
			if $bitsleft < 14 {
				r2 = Inflate.refill(input, $in_next, $bitbuf, $bitsleft, $overread)?
				$in_next = r2.in_next
				$bitbuf = r2.bitbuf
				$bitsleft = r2.bitsleft
				$overread = r2.overread
			} else {}

			entry = List.get(precode_table, $bitbuf.bitwise_and(127)) ?? 0
			consumed = entry.bitwise_and(255).to_u64()
			$bitbuf = $bitbuf.shr_zf_wrap(consumed.to_u8_wrap())
			$bitsleft = $bitsleft - consumed
			presym = entry.shr_zf_wrap(16).to_u64()

			if presym < 16 {
				$lens = match List.set($lens, $n, presym.to_u8_wrap()) {
					Ok(set_lens) => set_lens
					Err(_) => return Err(CorruptData)
				}
				$n = $n + 1
			} else if presym == 16 {
				# Repeat the previous length 3-6 times.
				if $n == 0 {
					return Err(Inflate.bad_data($bitsleft, $overread))
				} else {}
				rep_val = List.get($lens, $n - 1) ?? 0
				rep_count = 3 + $bitbuf.bitwise_and(3)
				$bitbuf = $bitbuf.shr_zf_wrap(2)
				$bitsleft = $bitsleft - 2
				var $r = 0.U64
				while $r < rep_count {
					$lens = match List.set($lens, $n + $r, rep_val) {
						Ok(set_lens) => set_lens
						Err(_) => return Err(CorruptData)
					}
					$r = $r + 1
				}
				$n = $n + rep_count
			} else if presym == 17 {
				# Repeat zero 3-10 times.
				rep_count = 3 + $bitbuf.bitwise_and(7)
				$bitbuf = $bitbuf.shr_zf_wrap(3)
				$bitsleft = $bitsleft - 3
				$n = $n + rep_count
			} else {
				# Repeat zero 11-138 times.
				rep_count = 11 + $bitbuf.bitwise_and(127)
				$bitbuf = $bitbuf.shr_zf_wrap(7)
				$bitsleft = $bitsleft - 7
				$n = $n + rep_count
			}
		}

		if $n != num_lens {
			return Err(Inflate.bad_data($bitsleft, $overread))
		} else {}

		Ok({
			in_next: $in_next,
			bitbuf: $bitbuf,
			bitsleft: $bitsleft,
			overread: $overread,
			lens: $lens,
			num_litlen_syms,
			num_offset_syms,
			precode: precode_table,
			offsets: precode_built.offsets,
			sorted: precode_built.sorted,
		})
	}

	InflateResult : {
		in_next : U64,
		bitbuf : U64,
		bitsleft : U64,
		overread : U64,
		out : List(U8),
		litlen : List(U32),
		offset : List(U32),
	}

	## Decode one Huffman block's symbols into the output. Ported from the
	## template's generic loop: one refill per iteration covers the longest
	## litlen codeword, its extra bits, and an offset table preload.
	##
	## `out_start` is where the stream's output begins in `out0`. A match may
	## reach back across earlier blocks but never before that.
	inflate_block : List(U8), U64, U64, U64, U64, List(U8), U64, U64, BlockTables -> Try(InflateResult, [CorruptData, UnexpectedEnd, OutputLimitExceeded])
	inflate_block = |input, in_next0, bitbuf0, bitsleft0, overread0, out0, out_start, out_limit, tables| {
		litlen_table = tables.litlen
		litlen_mask = tables.litlen_mask
		offset_table = tables.offset
		# Every root litlen lookup masks with `litlen_mask` and every root
		# offset lookup masks with 255. Bounding both tables once keeps
		# those loads in bounds through the whole block.
		if litlen_mask >= List.len(litlen_table) {
			return Err(CorruptData)
		} else {}
		if List.len(offset_table) <= 255 {
			return Err(CorruptData)
		} else {}

		in_len = List.len(input)

		var $in_next = in_next0
		var $bitbuf = bitbuf0
		var $bitsleft = bitsleft0
		var $overread = overread0
		var $out = out0
		var $done = 0.U64

		# Fast loop: decode several symbols per unguarded word refill,
		# decoding ahead by one: every back edge refills and preloads the next
		# symbol's entry, so its table-load latency overlaps the match copy.
		# The 24-byte margin covers any two refills an iteration can perform
		# (each advances the cursor by at most seven bytes and reads eight),
		# counted without path splitting: a cursor within 14 bytes of the
		# iteration start plus an eight-byte read stays inside 24. That bound
		# holds on every path, so the compiler's range proofs discharge each
		# refill's bounds test without reasoning about which paths exclude
		# each other.
		# The entry cursor is caller-controlled. Bounding it once lets the
		# compiler's range proofs discharge the margin addition's overflow
		# check on every iteration below.
		if in_next0 > in_len {
			return Err(CorruptData)
		} else {}

		# The fast loop runs only while one iteration's worst case still fits
		# under the output limit, as libdeflate's `out_fastloop_end` does, so
		# its appends need no checks of their own. The careful loop checks
		# every symbol, and with less than an iteration's room left it decodes
		# the few bytes before the limit.
		out_fast_end = if out_limit >= Inflate.fast_loop_max_output {
			out_limit - Inflate.fast_loop_max_output + 1
		} else {
			0
		}

		var $entry = 0.U32
		if $in_next + 24 <= in_len {
			word0 = U64.from_le_bytes(input, $in_next) ?? 0
			$bitbuf = $bitbuf.bitwise_or(word0.shl_wrap($bitsleft.to_u8_wrap()))
			$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
			$bitsleft = $bitsleft.bitwise_or(56)
			$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
		} else {}
		while $done == 0 and $in_next + 24 <= in_len and List.len($out) < out_fast_end {
			var $saved_bitbuf = $bitbuf
			$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
			$bitsleft = $bitsleft.minus_wrap($entry.to_u64())

			# Literals are tested for first, as the common case, and only from
			# the main table: an entry that is neither a literal nor a plain
			# length is exceptional, a subtable pointer or the end of the block,
			# and is sorted out after the literal tests have failed. That keeps
			# every fast literal to at most a table index of bits, which is what
			# lets each next entry below be looked up before its refill: enough
			# bits are always left for the index, and a refill only adds bits
			# above them, so the lookup never waits on the refill.
			var $pending = 1.U64
			if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
				$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
				$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
				$saved_bitbuf = $bitbuf
				$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
				if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
					$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
					$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
					$saved_bitbuf = $bitbuf
					$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
					$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
					if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
						$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
						$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
						word3 = U64.from_le_bytes(input, $in_next) ?? 0
						$bitbuf = $bitbuf.bitwise_or(word3.shl_wrap($bitsleft.to_u8_wrap()))
						$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
						$bitsleft = $bitsleft.bitwise_or(56)
						$pending = 0
					} else {}
				} else {}
			} else {}

			if $pending == 1 and $entry.bitwise_and(Inflate.huffdec_exceptional) != 0 {
				if $entry.bitwise_and(Inflate.huffdec_end_of_block) != 0 {
					$done = 1
					$pending = 0
				} else {
					sub_mask = 1.U64.shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
					sub_index = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sub_mask)
					$entry = (List.get(litlen_table, sub_index) ?? 0)
					$saved_bitbuf = $bitbuf
					$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
					$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
					if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
						$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
						$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
						word_s = U64.from_le_bytes(input, $in_next) ?? 0
						$bitbuf = $bitbuf.bitwise_or(word_s.shl_wrap($bitsleft.to_u8_wrap()))
						$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
						$bitsleft = $bitsleft.bitwise_or(56)
						$pending = 0
					} else if $entry.bitwise_and(Inflate.huffdec_end_of_block) != 0 {
						$done = 1
						$pending = 0
					} else {}
				}
			} else {}

			if $pending == 1 {
				len_codeword_bits = $entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				len_mask = 1.U64.shl_wrap($entry.to_u8_wrap()) - 1
				length = $entry.shr_zf_wrap(16).to_u64()
					+ $saved_bitbuf.bitwise_and(len_mask).shr_zf_wrap(len_codeword_bits)

				# The offset entry is looked up from the bits in hand. Whether a
				# refill is needed before its extra bits is decided afterwards. The
				# thresholds leave a table index of bits after the offset, for the
				# preload below.
				var $off_entry = (List.get(offset_table, $bitbuf.bitwise_and(255)) ?? 0)
				if $off_entry.bitwise_and(Inflate.huffdec_exceptional) != 0 {
					if $bitsleft.bitwise_and(255) < 38 {
						word_x = U64.from_le_bytes(input, $in_next) ?? 0
						$bitbuf = $bitbuf.bitwise_or(word_x.shl_wrap($bitsleft.to_u8_wrap()))
						$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
						$bitsleft = $bitsleft.bitwise_or(56)
					} else {}
					$bitbuf = $bitbuf.shr_zf_wrap(8)
					$bitsleft = $bitsleft.minus_wrap(8)
					osm = 1.U64.shl_wrap($off_entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
					osi = $off_entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(osm)
					$off_entry = (List.get(offset_table, osi) ?? 0)
				} else if $bitsleft.bitwise_and(255) < 31 {
					word_r = U64.from_le_bytes(input, $in_next) ?? 0
					$bitbuf = $bitbuf.bitwise_or(word_r.shl_wrap($bitsleft.to_u8_wrap()))
					$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
					$bitsleft = $bitsleft.bitwise_or(56)
				} else {}
				off_codeword_bits = $off_entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				off_mask = 1.U64.shl_wrap($off_entry.to_u8_wrap()) - 1
				offset = $off_entry.shr_zf_wrap(16).to_u64()
					+ $bitbuf.bitwise_and(off_mask).shr_zf_wrap(off_codeword_bits)
				$bitbuf = $bitbuf.shr_zf_wrap($off_entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($off_entry.to_u64())

				# The fast loop stops 24 bytes short of the input end, so every
				# bit it has consumed is real and a bad offset is corrupt data.
				out_len = List.len($out)
				if offset > out_len - out_start or offset == 0 {
					return Err(CorruptData)
				} else {}

				# Preload the next symbol and refill before the copy runs, so
				# their latency hides under the copy's stores.
				$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
				word2 = U64.from_le_bytes(input, $in_next) ?? 0
				$bitbuf = $bitbuf.bitwise_or(word2.shl_wrap($bitsleft.to_u8_wrap()))
				$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
				$bitsleft = $bitsleft.bitwise_or(56)

				$out = match List.append_range_within($out, out_len - offset, length) {
					Ok(new_out) => new_out
					Err(_) => return Err(CorruptData)
				}
			} else {}
		}

		# Careful loop: one symbol per iteration, for the tail of the input and
		# the last bytes before the limit.
		while $done == 0 {
			if $bitsleft.bitwise_and(255) < 32 {
				r = Inflate.refill(input, $in_next, $bitbuf, $bitsleft, $overread)?
				$in_next = r.in_next
				$bitbuf = r.bitbuf
				$bitsleft = r.bitsleft
				$overread = r.overread
			} else {}

			$entry = List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0
			var $saved_bitbuf = $bitbuf
			$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
			$bitsleft = $bitsleft.minus_wrap($entry.to_u64())

			if $entry.bitwise_and(Inflate.huffdec_subtable_pointer) != 0 {
				sub_mask = 1.U64.shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
				sub_index = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sub_mask)
				$entry = List.get(litlen_table, sub_index) ?? 0
				$saved_bitbuf = $bitbuf
				$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
			} else {}

			if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
				if List.len($out) >= out_limit {
					return Err(Inflate.over_limit($bitsleft, $overread))
				} else {}
				$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
			} else if $entry.bitwise_and(Inflate.huffdec_end_of_block) != 0 {
				break
			} else {
				# Length: base plus extra bits, both packed in the entry.
				len_codeword_bits = $entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				len_mask = 1.U64.shl_wrap($entry.to_u8_wrap()) - 1
				length = $entry.shr_zf_wrap(16).to_u64()
					+ $saved_bitbuf.bitwise_and(len_mask).shr_zf_wrap(len_codeword_bits)

				# Offset: up to 15+13 codeword and extra bits, plus the 32
				# already guaranteed, always fit after one refill.
				if $bitsleft.bitwise_and(255) < 28 {
					r2 = Inflate.refill(input, $in_next, $bitbuf, $bitsleft, $overread)?
					$in_next = r2.in_next
					$bitbuf = r2.bitbuf
					$bitsleft = r2.bitsleft
					$overread = r2.overread
				} else {}

				var $off_entry = List.get(offset_table, $bitbuf.bitwise_and(255)) ?? 0
				if $off_entry.bitwise_and(Inflate.huffdec_exceptional) != 0 {
					$bitbuf = $bitbuf.shr_zf_wrap(8)
					$bitsleft = $bitsleft.minus_wrap(8)
					off_sub_mask = 1.U64.shl_wrap($off_entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
					off_sub_index = $off_entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(off_sub_mask)
					$off_entry = List.get(offset_table, off_sub_index) ?? 0
				} else {}
				off_codeword_bits = $off_entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				off_mask = 1.U64.shl_wrap($off_entry.to_u8_wrap()) - 1
				offset = $off_entry.shr_zf_wrap(16).to_u64()
					+ $bitbuf.bitwise_and(off_mask).shr_zf_wrap(off_codeword_bits)
				$bitbuf = $bitbuf.shr_zf_wrap($off_entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($off_entry.to_u64())

				out_len = List.len($out)
				if offset > out_len - out_start or offset == 0 {
					return Err(Inflate.bad_data($bitsleft, $overread))
				} else {}
				if length > out_limit - out_len {
					return Err(Inflate.over_limit($bitsleft, $overread))
				} else {}


				# The match is `length` bytes starting `offset` back in the
				# output. Reading through freshly appended bytes is what
				# makes an overlapping range repeat, exactly the copy
				# `append_range_within` performs.
				$out = match List.append_range_within($out, out_len - offset, length) {
					Ok(new_out) => new_out
					Err(_) => return Err(CorruptData)
				}
			}
		}

		Ok({
			in_next: $in_next,
			bitbuf: $bitbuf,
			bitsleft: $bitsleft.bitwise_and(255),
			overread: $overread,
			out: $out,
			litlen: litlen_table,
			offset: offset_table,
		})
	}
}

import DeflateTables

## DEFLATE decompression, ported from libdeflate's `deflate_decompress.c` and
## `decompress_template.h`.
##
## The shape follows libdeflate rather than a textbook inflate: Huffman symbols
## are decoded with a first-level table indexed by the next `table_bits` input
## bits (plus one level of subtables for the rare longer codewords), and the
## bitstream is kept in a 64-bit buffer refilled eight bytes at a time. Each
## decode table entry packs everything a decode step needs -- symbol or base
## value, codeword length, and extra-bit count -- so the hot loop is a table
## load, a shift, and a subtract, instead of a walk over code lengths one bit
## at a time.
Inflate := [].{

	## Decompress a raw DEFLATE stream.
	##
	## Mirrors `libdeflate_deflate_decompress`'s generic loop. Input past the
	## final block is ignored, matching a stream embedded in a larger buffer.
	decompress : List(U8) -> Try(List(U8), [CorruptData, UnexpectedEnd])
	decompress = |input|
		Inflate.decompress_into(input, List.with_capacity(List.len(input) * 3))

	## Decompress a raw DEFLATE stream, appending the output to `out`.
	##
	## The caller controls the output allocation: passing a list with enough
	## spare capacity for the whole result (libdeflate's own calling
	## convention, where the caller always supplies the output buffer) means
	## the decompressor never reallocates mid-stream, and a returned list can
	## be emptied with its capacity kept and passed back in to decompress the
	## next stream with no fresh allocation.
	decompress_into : List(U8), List(U8) -> Try(List(U8), [CorruptData, UnexpectedEnd])
	decompress_into = |input, out| {
		in_len = List.len(input)

		var $out = out
		var $in_next = 0.U64
		var $bitbuf = 0.U64
		var $bitsleft = 0.U64
		var $overread = 0.U64
		var $more_blocks = True

		# The two big decode tables are built fresh for every block but into
		# the same allocations, which round-trip through build_block_tables
		# and inflate_block back here. Rebuilding writes every entry a decode
		# can read, so the leftover entries never need clearing.
		var $litlen_scratch = List.repeat(0.U32, Inflate.litlen_enough)
		var $offset_scratch = List.repeat(0.U32, Inflate.offset_enough)

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
				# bytes are returned to the input cursor first.
				$bitsleft = $bitsleft - 3
				unread = $bitsleft.shr_zf_wrap(3)
				if $overread > unread {
					return Err(CorruptData)
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
				$out = List.append_sublist($out, input, { start: $in_next, len })
				$in_next = $in_next + len
			} else if block_type <= 2 {
				tables =
					if block_type == 2 {
						# Dynamic Huffman block: read the header and the
						# run-length-encoded codeword lengths.
						header = Inflate.read_dynamic_header(input, $in_next, $bitbuf, $bitsleft, $overread)?
						$in_next = header.in_next
						$bitbuf = header.bitbuf
						$bitsleft = header.bitsleft
						$overread = header.overread
						Inflate.build_block_tables(header.lens, header.num_litlen_syms, header.num_offset_syms, $litlen_scratch, $offset_scratch)?
					} else {
						# Static Huffman block: the fixed code lengths from
						# RFC 1951 section 3.2.6.
						$bitbuf = $bitbuf.shr_zf_wrap(3)
						$bitsleft = $bitsleft - 3
						lens = List.repeat(8.U8, 144)
							.concat(List.repeat(9.U8, 112))
							.concat(List.repeat(7.U8, 24))
							.concat(List.repeat(8.U8, 8))
							.concat(List.repeat(5.U8, 32))
						Inflate.build_block_tables(lens, 288, 32, $litlen_scratch, $offset_scratch)?
					}

				decoded = Inflate.inflate_block(input, $in_next, $bitbuf, $bitsleft, $overread, $out, tables)?
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
			Ok($out)
		}
	}

	# --- Input bitstream ---
	#
	# `bitbuf` holds unconsumed bits with the next bit at bit 0; `bitsleft`
	# counts them. A refill loads eight input bytes at once when they exist
	# (`U64.from_le_bytes` and shifting by the current fill, advancing the
	# cursor by however many whole bytes fit), and falls back to byte-at-a-time
	# near the end of input, appending implicit zero bytes and counting them in
	# `overread` so truncation is detected when those zeros would be consumed.
	# After either refill at least 56 bits are available.

	RefillState : { in_next : U64, bitbuf : U64, bitsleft : U64, overread : U64 }

	refill : List(U8), U64, U64, U64, U64 -> Try(RefillState, [CorruptData, UnexpectedEnd])
	refill = |input, in_next, bitbuf, bitsleft_raw, overread| {
		# Consumes subtract whole decode entries from `bitsleft`, so only its
		# low byte is meaningful; recover the exact count once here.
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

	BuiltTable : { table : List(U32), table_bits : U64 }

	## Build a decode table for one canonical Huffman code from its codeword
	## lengths. Ported from `build_decode_table`; see that function for the
	## details of subtable layout and the incremental table-doubling fill.
	##
	## When `dynamic_table_bits` is set, `table_bits` is treated as a maximum
	## and reduced to the longest codeword length actually used (libdeflate
	## does this for the litlen table only).
	##
	## `scratch` supplies the table's backing storage, sized `enough` for the
	## code by its caller; every entry a decode can reach is written before
	## the table is returned, so a previous block's table can be passed back
	## in as it stands.
	build_decode_table : List(U8), U64, List(U32), U64, U64, Bool, List(U32) -> Try(BuiltTable, [CorruptData, UnexpectedEnd])
	build_decode_table = |lens, num_syms, decode_results, max_table_bits, max_codeword_len_limit, dynamic_table_bits, scratch| {
		# The per-symbol loops below index `lens` by every symbol under
		# `num_syms` and the per-length tables by codeword lengths up to
		# `max_codeword_len_limit`; bounding everything once up front keeps
		# each loop's element accesses in bounds.
		if List.len(lens) < num_syms {
			return Err(CorruptData)
		} else {}
		# Count codewords of each length, including length 0.
		var $len_counts = List.repeat(0.U64, max_codeword_len_limit + 1)
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
		# in bounds; entries past the trimmed maximum stay zero and unread.
		var $offsets = List.repeat(0.U64, max_codeword_len_limit + 2)
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

		var $sorted_syms = List.repeat(0.U16, num_syms)
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
		# Index of the first used symbol; everything before it has length 0.
		first_used = (List.get($offsets, 0) ?? 0)

		full = (1.U64).shl_wrap($max_codeword_len.to_u8_wrap())
		if $codespace_used > full {
			return Err(CorruptData)
		} else {}

		if $codespace_used < full {
			# An incomplete code is allowed only when empty or when it has a
			# single codeword of length 1; either maps to a complete
			# one-symbol code so the decoder needs no error entries.
			single_sym =
				if $codespace_used == 0 {
					0.U64
				} else {
					if $codespace_used != (1.U64).shl_wrap(($max_codeword_len - 1).to_u8_wrap()) or (List.get($len_counts, 1) ?? 0) != 1 {
						return Err(CorruptData)
					} else {}
					(List.get($sorted_syms, first_used) ?? 0).to_u64()
				}
			entry = Inflate.make_entry(decode_results, single_sym, 1)
			var $table0 = scratch
			var $i = 0.U64
			table_len = (1.U64).shl_wrap(table_bits.to_u8_wrap())
			while $i < table_len {
				$table0 = match List.set($table0, $i, entry) {
					Ok(set_table0) => set_table0
					Err(_) => return Err(CorruptData)
				}
				$i = $i + 1
			}
			return Ok({ table: $table0, table_bits })
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
		var $cur_table_end = (1.U64).shl_wrap($len.to_u8_wrap())

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
					return Ok({ table: $table, table_bits })
				} else {}

				# Advance to the lexicographically next bit-reversed codeword.
				flipped = $codeword.bitwise_xor($cur_table_end - 1).to_u32_wrap()
				bit_index = 31 - U32.count_leading_zero_bits(flipped)
				bit = (1.U64).shl_wrap(bit_index.to_u8_wrap())
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
		$cur_table_end = (1.U64).shl_wrap(table_bits.to_u8_wrap())
		var $subtable_prefix = 0xFFFFFFFF.U64
		var $subtable_start = 0.U64
		table_mask = (1.U64).shl_wrap(table_bits.to_u8_wrap()) - 1
		while True {
			if $codeword.bitwise_and(table_mask) != $subtable_prefix {
				$subtable_prefix = $codeword.bitwise_and(table_mask)
				$subtable_start = $cur_table_end
				# Subtable length: long enough that the remaining codewords
				# can fill it exactly.
				var $subtable_bits = $len - table_bits
				var $codespace = $count
				while $codespace < (1.U64).shl_wrap($subtable_bits.to_u8_wrap()) {
					$subtable_bits = $subtable_bits + 1
					$codespace = $codespace.shl_wrap(1) + (List.get($len_counts, table_bits + $subtable_bits) ?? 0)
				}
				$cur_table_end = $subtable_start + (1.U64).shl_wrap($subtable_bits.to_u8_wrap())

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
			stride = (1.U64).shl_wrap(($len - table_bits).to_u8_wrap())
			while $i2 < $cur_table_end {
				$table = match List.set($table, $i2, entry) {
					Ok(set_table) => set_table
					Err(_) => return Err(CorruptData)
				}
				$i2 = $i2 + stride
			}

			if $codeword == (1.U64).shl_wrap($len.to_u8_wrap()) - 1 {
				return Ok({ table: $table, table_bits })
			} else {}
			flipped2 = $codeword.bitwise_xor((1.U64).shl_wrap($len.to_u8_wrap()) - 1).to_u32_wrap()
			bit_index2 = 31 - U32.count_leading_zero_bits(flipped2)
			bit2 = (1.U64).shl_wrap(bit_index2.to_u8_wrap())
			$codeword = $codeword.bitwise_and(bit2 - 1).bitwise_or(bit2)
			$count = $count - 1
			while $count == 0 {
				$len = $len + 1
				$count = List.get($len_counts, $len) ?? 0
			}
		}

		Err(CorruptData)
	}

	BlockTables : { litlen : List(U32), litlen_mask : U64, offset : List(U32) }

	## Build the litlen and offset decode tables for one block's code lengths,
	## where `lens` holds the litlen lengths followed by the offset lengths.
	## The scratch lists supply the tables' backing storage, and the
	## decode-result halves are built once per stream by the caller.
	build_block_tables : List(U8), U64, U64, List(U32), List(U32) -> Try(BlockTables, [CorruptData, UnexpectedEnd])
	build_block_tables = |lens, num_litlen_syms, num_offset_syms, litlen_scratch, offset_scratch| {
		offset_lens = List.sublist(lens, { start: num_litlen_syms, len: num_offset_syms })
		offset_built = Inflate.build_decode_table(
			offset_lens,
			num_offset_syms,
			Inflate.offset_decode_results,
			Inflate.offset_tablebits,
			15,
			False,
			offset_scratch,
		)?
		litlen_built = Inflate.build_decode_table(
			List.sublist(lens, { start: 0, len: num_litlen_syms }),
			num_litlen_syms,
			Inflate.litlen_decode_results,
			Inflate.litlen_tablebits,
			15,
			True,
			litlen_scratch,
		)?
		Ok({
			litlen: litlen_built.table,
			litlen_mask: (1.U64).shl_wrap(litlen_built.table_bits.to_u8_wrap()) - 1,
			offset: offset_built.table,
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
	}

	## The order precode codeword lengths are stored in.
	precode_lens_permutation : List(U8)
	precode_lens_permutation = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

	## Read a dynamic Huffman block's header: the counts, the precode, and the
	## run-length-encoded litlen and offset codeword lengths.
	##
	## On entry the bitbuffer still holds BFINAL and BTYPE; they are consumed
	## here together with the counts, exactly as in the template.
	read_dynamic_header : List(U8), U64, U64, U64, U64 -> Try(DynamicHeader, [CorruptData, UnexpectedEnd])
	read_dynamic_header = |input, in_next0, bitbuf0, bitsleft0, overread0| {
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
			List.repeat(0.U32, Inflate.precode_enough),
		)?
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
		var $lens = List.repeat(0.U8, 288 + 32 + 137)
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
					return Err(CorruptData)
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
			return Err(CorruptData)
		} else {}

		Ok({
			in_next: $in_next,
			bitbuf: $bitbuf,
			bitsleft: $bitsleft,
			overread: $overread,
			lens: $lens,
			num_litlen_syms,
			num_offset_syms,
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
	inflate_block : List(U8), U64, U64, U64, U64, List(U8), BlockTables -> Try(InflateResult, [CorruptData, UnexpectedEnd])
	inflate_block = |input, in_next0, bitbuf0, bitsleft0, overread0, out0, tables| {
		litlen_table = tables.litlen
		litlen_mask = tables.litlen_mask
		offset_table = tables.offset
		# Every root litlen lookup masks with `litlen_mask` and every root
		# offset lookup masks with 255; bounding both tables once keeps
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

		# ── Fast loop ── decode several symbols per unguarded word refill,
		# decoding ahead by one: every back edge refills and preloads the next
		# symbol's entry, so its table-load latency overlaps the match copy.
		# The 24-byte margin covers any two refills an iteration can perform
		# (each advances the cursor by at most seven bytes and reads eight),
		# counted without path splitting: a cursor within 14 bytes of the
		# iteration start plus an eight-byte read stays inside 24. That bound
		# holds on every path, so the compiler's range proofs discharge each
		# refill's bounds test without reasoning about which paths exclude
		# each other.
		# The entry cursor is caller-controlled; bounding it once lets the
		# compiler's range proofs discharge the margin addition's overflow
		# check on every iteration below.
		if in_next0 > in_len {
			return Err(CorruptData)
		} else {}

		var $entry = 0.U32
		if $in_next + 24 <= in_len {
			word0 = U64.from_le_bytes(input, $in_next) ?? 0
			$bitbuf = $bitbuf.bitwise_or(word0.shl_wrap($bitsleft.to_u8_wrap()))
			$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
			$bitsleft = $bitsleft.bitwise_or(56)
			$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
		} else {}
		while $done == 0 and $in_next + 24 <= in_len {
			var $saved_bitbuf = $bitbuf
			$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
			$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
			if $entry.bitwise_and(Inflate.huffdec_subtable_pointer) != 0 {
				sub_mask = (1.U64).shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
				sub_index = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sub_mask)
				$entry = (List.get(litlen_table, sub_index) ?? 0)
				$saved_bitbuf = $bitbuf
				$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
			} else {}

			var $pending = 1.U64
			if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
				$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
				$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
				$saved_bitbuf = $bitbuf
				$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
				if $entry.bitwise_and(Inflate.huffdec_subtable_pointer) != 0 {
					sm2 = (1.U64).shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
					si2 = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sm2)
					$entry = (List.get(litlen_table, si2) ?? 0)
					$saved_bitbuf = $bitbuf
					$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
					$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
				} else {}
				if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
					$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
					$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
					$saved_bitbuf = $bitbuf
					$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
					$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
					if $entry.bitwise_and(Inflate.huffdec_subtable_pointer) != 0 {
						sm3 = (1.U64).shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
						si3 = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sm3)
						$entry = (List.get(litlen_table, si3) ?? 0)
						$saved_bitbuf = $bitbuf
						$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
						$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
					} else {}
					if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
						$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
						word3 = U64.from_le_bytes(input, $in_next) ?? 0
						$bitbuf = $bitbuf.bitwise_or(word3.shl_wrap($bitsleft.to_u8_wrap()))
						$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
						$bitsleft = $bitsleft.bitwise_or(56)
						$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)
						$pending = 0
					} else {}
				} else {}
			} else {}

			if $pending == 1 {
				if $entry.bitwise_and(Inflate.huffdec_end_of_block) != 0 {
					$done = 1
				} else {
					len_codeword_bits = $entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
					len_mask = (1.U64).shl_wrap($entry.to_u8_wrap()) - 1
					length = $entry.shr_zf_wrap(16).to_u64()
						+ $saved_bitbuf.bitwise_and(len_mask).shr_zf_wrap(len_codeword_bits)

					if $bitsleft.bitwise_and(255) < 28 {
						word_r = U64.from_le_bytes(input, $in_next) ?? 0
						$bitbuf = $bitbuf.bitwise_or(word_r.shl_wrap($bitsleft.to_u8_wrap()))
						$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
						$bitsleft = $bitsleft.bitwise_or(56)
					} else {}

					var $off_entry = (List.get(offset_table, $bitbuf.bitwise_and(255)) ?? 0)
					if $off_entry.bitwise_and(Inflate.huffdec_exceptional) != 0 {
						$bitbuf = $bitbuf.shr_zf_wrap(8)
						$bitsleft = $bitsleft.minus_wrap(8)
						osm = (1.U64).shl_wrap($off_entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
						osi = $off_entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(osm)
						$off_entry = (List.get(offset_table, osi) ?? 0)
					} else {}
					off_codeword_bits = $off_entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
					off_mask = (1.U64).shl_wrap($off_entry.to_u8_wrap()) - 1
					offset = $off_entry.shr_zf_wrap(16).to_u64()
						+ $bitbuf.bitwise_and(off_mask).shr_zf_wrap(off_codeword_bits)
					$bitbuf = $bitbuf.shr_zf_wrap($off_entry.to_u8_wrap())
					$bitsleft = $bitsleft.minus_wrap($off_entry.to_u64())

					out_len = List.len($out)
					if offset > out_len or offset == 0 {
						return Err(CorruptData)
					} else {}

					# Refill and preload the next symbol before the copy runs,
					# so its table-load latency hides under the copy's stores.
					word2 = U64.from_le_bytes(input, $in_next) ?? 0
					$bitbuf = $bitbuf.bitwise_or(word2.shl_wrap($bitsleft.to_u8_wrap()))
					$in_next = $in_next + 7 - $bitsleft.shr_zf_wrap(3).bitwise_and(7)
					$bitsleft = $bitsleft.bitwise_or(56)
					$entry = (List.get(litlen_table, $bitbuf.bitwise_and(litlen_mask)) ?? 0)

					$out = match List.append_range_within($out, out_len - offset, length) {
						Ok(new_out) => new_out
						Err(_) => return Err(CorruptData)
					}
				}
			} else {}
		}

		# ── Careful loop ── one symbol per iteration, tail of input.
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
				sub_mask = (1.U64).shl_wrap($entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
				sub_index = $entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(sub_mask)
				$entry = List.get(litlen_table, sub_index) ?? 0
				$saved_bitbuf = $bitbuf
				$bitbuf = $bitbuf.shr_zf_wrap($entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($entry.to_u64())
			} else {}

			if $entry.bitwise_and(Inflate.huffdec_literal) != 0 {
				$out = List.append($out, $entry.shr_zf_wrap(16).to_u8_wrap())
			} else if $entry.bitwise_and(Inflate.huffdec_end_of_block) != 0 {
				break
			} else {
				# Length: base plus extra bits, both packed in the entry.
				len_codeword_bits = $entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				len_mask = (1.U64).shl_wrap($entry.to_u8_wrap()) - 1
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
					off_sub_mask = (1.U64).shl_wrap($off_entry.shr_zf_wrap(8).bitwise_and(63).to_u8_wrap()) - 1
					off_sub_index = $off_entry.shr_zf_wrap(16).to_u64() + $bitbuf.bitwise_and(off_sub_mask)
					$off_entry = List.get(offset_table, off_sub_index) ?? 0
				} else {}
				off_codeword_bits = $off_entry.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()
				off_mask = (1.U64).shl_wrap($off_entry.to_u8_wrap()) - 1
				offset = $off_entry.shr_zf_wrap(16).to_u64()
					+ $bitbuf.bitwise_and(off_mask).shr_zf_wrap(off_codeword_bits)
				$bitbuf = $bitbuf.shr_zf_wrap($off_entry.to_u8_wrap())
				$bitsleft = $bitsleft.minus_wrap($off_entry.to_u64())

				out_len = List.len($out)
				if offset > out_len or offset == 0 {
					return Err(CorruptData)
				} else {}

				# The match is `length` bytes starting `offset` back in the
				# output; reading through freshly appended bytes is what
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

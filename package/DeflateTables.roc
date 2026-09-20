## Fixed tables DEFLATE (RFC 1951) defines, transcribed from libdeflate so the
## two agree symbol for symbol.
##
## These are not arbitrary: the length and offset slot bases, together with the
## extra-bit counts, are what turn a (length, offset) pair into the symbol and
## extra bits that go on the wire, so any disagreement here changes the output
## stream rather than merely its size.
DeflateTables := [].{
	## Number of extra bits carried by each precode symbol. Only the three
	## run-length symbols (16, 17, 18) have any.
	extra_precode_bits : List(U8)
	extra_precode_bits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7]

	## Extra bits for each length slot, indexed from litlen symbol 257.
	extra_length_bits : List(U8)
	extra_length_bits = [
		0, 0, 0, 0, 0, 0, 0, 0,
		1, 1, 1, 1, 2, 2, 2, 2,
		3, 3, 3, 3, 4, 4, 4, 4,
		5, 5, 5, 5, 0,
	]

	## Smallest match length encoded by each length slot.
	length_slot_base : List(U32)
	length_slot_base = [
		3, 4, 5, 6, 7, 8, 9, 10,
		11, 13, 15, 17, 19, 23, 27, 31,
		35, 43, 51, 59, 67, 83, 99, 115,
		131, 163, 195, 227, 258,
	]

	## Extra bits for each offset slot.
	extra_offset_bits : List(U8)
	extra_offset_bits = [
		0, 0, 0, 0, 1, 1, 2, 2,
		3, 3, 4, 4, 5, 5, 6, 6,
		7, 7, 8, 8, 9, 9, 10, 10,
		11, 11, 12, 12, 13, 13,
	]

	## Smallest match offset encoded by each offset slot.
	offset_slot_base : List(U32)
	offset_slot_base = [
		1, 2, 3, 4, 5, 7, 9, 13,
		17, 25, 33, 49, 65, 97, 129, 193,
		257, 385, 513, 769, 1025, 1537, 2049, 3073,
		4097, 6145, 8193, 12289, 16385, 24577,
	]

	## The order in which precode codeword lengths are stored on the wire.
	precode_lens_permutation : List(U8)
	precode_lens_permutation = [
		16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
	]

	## Length slot for every match length, indexed by the length itself. A
	## direct table rather than a search: the parser converts a length to its
	## slot for every match it emits.
	length_slot_tab : List(U8)
	length_slot_tab = [
		0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 12,
		12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 17,
		17, 17, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19,
		19, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 21, 21, 21, 21, 21,
		21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22,
		22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 24,
		24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
		24, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
		25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 26, 26, 26,
		26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
		26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
		27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28,
	]

	## Offset slot for `offset - 1`, for offsets up to 256. Offsets above that
	## reuse this table shifted; see [DeflateTables.offset_slot].
	offset_slot_tab : List(U8)
	offset_slot_tab = [
		0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
		8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9,
		10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
		11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
	]

	## Litlen symbol that ends a block.
	end_of_block : U64
	end_of_block = 256

	## First litlen symbol that encodes a match length.
	first_len_sym : U64
	first_len_sym = 257

	## The literal symbols, 0-255, which are what the end-of-block symbol
	## immediately follows.
	num_literals : U64
	num_literals = 256

	num_litlen_syms : U64
	num_litlen_syms = 288

	num_offset_syms : U64
	num_offset_syms = 32

	num_precode_syms : U64
	num_precode_syms = 19

	## The longest and shortest matches DEFLATE can encode.
	max_match_len : U64
	max_match_len = 258

	min_match_len : U64
	min_match_len = 3

	## The furthest back a match may reach.
	max_match_offset : U64
	max_match_offset = 32768

	## Block types, as they appear in the 2-bit BTYPE field.
	blocktype_uncompressed : U64
	blocktype_uncompressed = 0

	blocktype_static : U64
	blocktype_static = 1

	blocktype_dynamic : U64
	blocktype_dynamic = 2

	## The codeword lengths of the fixed ("static") litlen code, which RFC 1951
	## defines rather than transmitting.
	static_litlen_lens : List(U8)
	static_litlen_lens = {
		var $out = List.with_capacity(288)
		var $i = 0.U64
		while $i < 288 {
			len = if $i < 144 {
				8
			} else if $i < 256 {
				9
			} else if $i < 280 {
				7
			} else {
				8
			}
			$out = List.append($out, len)
			$i = $i + 1
		}
		$out
	}

	## The static offset code: all 32 symbols, 5 bits each.
	static_offset_lens : List(U8)
	static_offset_lens = List.repeat(5.U8, 32)

	## Length slot for a match length, i.e. which litlen symbol encodes it.
	length_slot : U64 -> U64
	length_slot = |length|
		(List.get(DeflateTables.length_slot_tab, length) ?? 0).to_u64()

	## Offset slot for a match offset, using the condensed 256-entry table.
	##
	## Slots 16 and up are each 128 times larger than slots 2 through 15, since
	## the extra-bit count rises by one every two slots, so one table serves
	## both ranges: shift the offset right by 7 above 256 and add 14 to the
	## slot. The shift amount comes from the sign of `256 - offset` rather than
	## a comparison, which is what libdeflate does.
	offset_slot : U64 -> U64
	offset_slot = |offset| {
		n = 256.U32.minus_wrap(offset.to_u32_wrap()).shr_zf_wrap(29).to_u64()
		(List.get(DeflateTables.offset_slot_tab, offset.minus_wrap(1).shr_zf_wrap(n.to_u8_wrap())) ?? 0).to_u64()
			.plus_wrap(n.shl_wrap(1))
	}
}

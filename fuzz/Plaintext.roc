## Plaintext with the structure DEFLATE looks for, built from fuzzer pieces.
##
## Random bytes barely compress, so a compressor fed only noise spends every
## run in its literal paths. Each piece here appends some literal bytes and
## then copies a run from earlier in the text, at any distance and length, so
## the matchfinders, the lazy and near-optimal parsers, and the decoder's match
## copies all see real work, including overlapping copies that repeat a short
## pattern and copies longer than the longest match.
Plaintext := [].{
	Piece : { literal : List(U8), back : U64, len : U64 }

	## The text the pieces describe. A copy reaches back `back` bytes, wrapped
	## to what has been written so far, and nothing is copied before the
	## first byte.
	expand : List(Piece) -> List(U8)
	expand = |pieces| {
		var $text = []
		for piece in pieces {
			$text = List.concat($text, piece.literal)
			written = List.len($text)
			if written > 0 and piece.len > 0 {
				distance = piece.back % written + 1
				$text = Plaintext.copy_back($text, distance, piece.len)
			}
		}
		$text
	}

	## Append `len` bytes copied from `distance` back, one byte at a time, so
	## a distance shorter than the run repeats it.
	copy_back : List(U8), U64, U64 -> List(U8)
	copy_back = |text, distance, len| {
		var $text = List.reserve(text, len)
		var $i = 0.U64
		while $i < len {
			byte = List.get($text, List.len($text) - distance) ?? 0
			$text = List.append($text, byte)
			$i = $i + 1
		}
		$text
	}
}

expect Plaintext.expand([]) == []

expect Plaintext.expand([{ literal: [1, 2], back: 1, len: 5 }]) == [1, 2, 1, 2, 1, 2, 1]

expect Plaintext.expand([{ literal: [], back: 3, len: 4 }, { literal: [9], back: 0, len: 2 }]) == [9, 9, 9]

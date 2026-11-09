app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import pf.OsStr
import deflate.Deflate

main! = |args| {
	# Compresses the text you pass on the command line, or this line if you
	# pass none
	original = match args.get(0) {
		Ok(arg) => OsStr.display(arg).to_utf8()
		Err(_) => "Bootcut Jeans, salmon shirt, I have a skin routine and my elbows hurt.".to_utf8()
	}

	compressed = Deflate.compress(original, 6)
	Stdout.line!("Compressed ${original.len().to_str()} bytes to ${compressed.len().to_str()}")?

	match Deflate.decompress(compressed) {
		Ok(decompressed) =>
			if decompressed == original {
				Stdout.line!("Round-trip successful")?
			} else {
				Stdout.line!("Round-trip mismatch!")?
			}
		Err(CorruptData) => Stdout.line!("Corrupt DEFLATE stream")?
		Err(UnexpectedEnd) => Stdout.line!("Truncated DEFLATE stream")?
	}

	Ok({})
}

//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.linebreak;

///Enumerates platform specific line breaks.
enum LineBreak {
	///Unix line break ("\n").
	Unix,
	///Windows line break ("\r\n").
	Windows,
	///Macintosh line break ("\r").
	Macintosh
}

//Get line break string for specified line break.
package string lineBreak(in LineBreak b) pure @safe nothrow {
	final switch (b) {
		case LineBreak.Unix:
			return "\n";
		case LineBreak.Windows:
			return "\r\n";
		case LineBreak.Macintosh:
			return "\r";
	}
}

//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)
module wyaml.anchor;

import std.algorithm;
import std.exception;
import std.range;
import std.typecons;
import std.uni;

struct Anchor {
	string data;
	alias get this;
	this(string input) {
		enforce(input.filter!(x => !x.isAlphaNum && !x.among('-', '_')).empty, new Exception("Invalid character in anchor"));
		data = input;
	}
	auto get() const @safe nothrow pure @nogc {
		if (isNull) {
			assert(0);
		}
		return data;
	}
	bool isNull() const @safe nothrow pure @nogc {
		return data == "";
	}
	static private auto invalid() {
		Anchor output;
		return output;
	}
}
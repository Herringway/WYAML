//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.inputoutput;

unittest {
	import std.array : front, join, split;
	import std.conv : to;

	import wyaml.loader : Loader;
	import wyaml.node : Node;
	import wyaml.tests.common : run2;

	/// Unicode input unittest. Tests various encodings.
	///
	/// Params:  data = Data to read.
	void testUnicodeInput(string data, string) {
		auto expected = data.split().join(" ");

		Node output = Loader(data).loadAll().front;
		assert(output.to!string == expected);
	}

	run2!(testUnicodeInput, ["unicode"], "latin")("I/O");
}

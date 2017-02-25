//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.common;

import std.conv;
import std.meta;

package void run2(alias func, string[] testExts, T...)(string testTitle) {
	import std.stdio : write, writeln;

	writeln("=========================================");
	writeln("WYAML ", testTitle, " test");
	scope (exit) {
		writeln("\nTests: ", T.length);
	}
	foreach (testName; T) {
		try {
			func(buildTestArgs!(testExts, testName), testName);
			write(".");
		} catch (Exception e) {
			write("Error");
			writeln(e);
		}
	}
}

package template buildTestArgs(string[] exts, string T) {
	static if (exts.length > 1) {
		alias buildTestArgs = AliasSeq!(import(T ~ "." ~ exts[0]), buildTestArgs!(exts[1 .. $], T));
	} else static if (exts.length == 1) {
		alias buildTestArgs = AliasSeq!(import(T ~ "." ~ exts[0]));
	} else {
		alias buildTestArgs = AliasSeq!();
	}
}

package void writeComparison(string expectedLabel = "Expected value", string actualLabel = "Actual value", T, U)(string testName, T expected, U actual) {
	import std.stdio : writeln;

	writeItem!expectedLabel(expected);
	writeln("\n");
	writeItem!actualLabel(actual);
}

package void writeComparison(string expectedLabel = "Expected value", T)(string testName, T expected) {
	import std.stdio : writeln;

	writeItem!expectedLabel(expected);
}

package void writeComparison(string expectedLabel = "Expected value", string secondLabel = "Actual value", string thirdLabel = "Output", T, U, V)(string testName, T expected, U actual, V output) {
	import std.stdio : writeln;

	writeItem!expectedLabel(expected);
	writeln("\n");
	writeItem!secondLabel(actual);
	writeln("\n");
	writeItem!thirdLabel(output);
}

package void writeItem(string label, T)(T item) {
	import std.stdio : writeln;

	writeln(label, ":");
	static if (is(typeof(item.debugString))) {
		writeln(item.debugString);
	} else {
		writeln(item.text);
	}
}

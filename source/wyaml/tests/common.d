//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.common;

public import std.conv;
public import std.stdio;
public import wyaml;

import core.exception;
import std.algorithm;
import std.array;
import std.bitmanip;
import std.conv;
import std.file;
import std.meta;
import std.path;
import std.string;
import std.system;
import std.typecons;
import std.utf;

package:

void run2(alias func, string[] testExts, T...)(string testTitle) {
	writeln("=========================================");
	writeln("WYAML ", testTitle, " test");
	scope(exit) {
		writeln("\nTests: ", T.length);
		writeln("=========================================");
	}
	foreach (testName; T) {
		try {
			func(buildTestArgs!(testExts, testName), testName);
			write(".");
		} catch (Exception e) {
			write("Error");
			version(verboseTest) {
				writeln(e);
			}
		}
	}
}
template buildTestArgs(string[] exts, string T) {
	static if (exts.length > 1)
		alias buildTestArgs = AliasSeq!(import(T~"."~exts[0]), buildTestArgs!(exts[1..$], T));
	else static if (exts.length == 1)
		alias buildTestArgs = AliasSeq!(import(T~"."~exts[0]));
	else
		alias buildTestArgs = AliasSeq!();
}
void writeComparison(T)(T expected, T actual) {
	version(verboseTest) {
		writeln("Expected value:");
		writeln(expected.debugString);
		writeln("\n");
		writeln("Actual value:");
		writeln(actual.debugString);
	}
}
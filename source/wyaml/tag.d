//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

///YAML tag.
module wyaml.tag;

import std.algorithm;
import std.array;
import std.exception;
import std.meta;
import std.uni;
import std.utf;

import wyaml.tagdirective;

package alias invalidTagChars = AliasSeq!('-', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')', '[', ']');

struct Tag {
	string data;
	alias get this;
	this(string input) @safe pure nothrow {
		data = input;
	}
	auto get() const @safe nothrow pure @nogc {
		if (isNull) {
			assert(0, "Tag is null");
		}
		return data;
	}
	bool isNull() const @safe nothrow pure @nogc {
		return data == "";
	}
	Tag withDirectives(TagDirective[] directives) const nothrow @safe pure {
		if (isNull) {
			assert(0, "Tag is null");
		}
		if (data == "!") {
			return this;
		}
		string tagString = data;
		string handle = null;
		string suffix = tagString;

		//Sort lexicographically by prefix.
		assumeWontThrow(directives.sort!"icmp(a.prefix, b.prefix) < 0"());
		foreach (pair; directives) {
			auto prefix = pair.prefix;
			if (tagString.startsWith(prefix.data) && (prefix != "!" || prefix.length < tagString.length)) {
				handle = pair.handle;
				suffix = tagString[prefix.length .. $];
			}
		}

		auto appender = appender!string();
		appender.put(handle !is null && handle != "" ? handle : "!<");
		size_t start = 0;
		size_t end = 0;
		foreach (c; suffix) {
			if (isAlphaNum(c) || c.among(invalidTagChars) || (c == '!' && handle != "!")) {
				++end;
				continue;
			}
			if (start < end) {
				appender.put(suffix[start .. end]);
			}
			start = end = end + 1;

			appender.put(c);
		}

		if (start < end) {
			appender.put(suffix[start .. end]);
		}
		if (handle is null || handle == "") {
			appender.put(">");
		}
		//Subsets and combinations of valid tags cannot become invalid.
		return Tag(appender.data);
	}
}
unittest {

}
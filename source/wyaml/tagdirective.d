//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

///Tag directives.
module wyaml.tagdirective;

import std.algorithm : all, startsWith, endsWith, among;
import std.ascii : isAlphaNum;
import std.exception : enforce;
import std.range;
import std.typecons : AliasSeq;
import std.uni : toLower;

///Default tag handle shortcuts and replacements.
package alias defaultTagDirectives = AliasSeq!(TagDirective("!", "!"), TagDirective("!!", "tag:yaml.org,2002:"));

///Single tag directive. handle is the shortcut, prefix is the prefix that replaces it.
struct TagDirective {
	struct Handle {
		string original;
		string data;
		alias data this;
		this(string input) {
			enforce(!input.empty, "Handle must not be empty");
			enforce(input.startsWith('!') && input.endsWith('!'), "Handle must begin and end with !");
			enforce((input.length == 1) || input[1..$-1].all!(a => isAlphaNum(a) || (a == '-')), "Illegal characters found in handle");
			original = input;
			data = input.toLower();
		}
	}
	struct Prefix {
		string data;
		alias data this;
		this(string input) {
			enforce(!input.empty, "Prefix must not be empty");
			enforce(input.all!(a => isAlphaNum(a) || a.among('%', '-', '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']')), "Illegal characters found in prefix");
			data = input;
		}
	}
	Handle handle;
	Prefix prefix;
	int opCmp(ref const TagDirective other) const {
		return this.handle > other.handle;
	}
	this(string inHandle, string inPrefix) {
		handle = Handle(inHandle);
		prefix = Prefix(inPrefix);
	}
}
unittest {
	import std.exception;
	assertNotThrown(TagDirective("!example!", "tag:example.org,2002:"));
	assertNotThrown(TagDirective("!yaml!", "tag:yaml.org,2002:"));
	assertNotThrown(TagDirective("!!", "tag:yaml.org,2002:"));
	assertNotThrown(TagDirective("!", "!"));
	assertNotThrown(TagDirective("!", "!foo"));
	assertThrown(TagDirective("", "!foo"));
	assertThrown(TagDirective("!foo", "!foo"));
	assertThrown(TagDirective("foo!", "!foo"));
}
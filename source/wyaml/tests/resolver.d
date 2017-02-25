//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.resolver;

unittest {
	import std.array : front;
	import std.meta : AliasSeq;
	import std.string : strip;

	import wyaml.loader : Loader;
	import wyaml.node : Node;
	import wyaml.tests.common : run2, writeComparison;

	/**
	 * Implicit tag resolution unittest.
	 *
	 * Params:  data   = Unittest data.
	 *          detect = Correct tag to look for.
	 */
	void testImplicitResolver(string data, string detect, string testName) {
		string correctTag;
		Node node;

		scope (failure) {
			writeComparison!("Correct tag", "Node")(testName, correctTag, node);
		}

		correctTag = detect.strip();
		node = Loader(data).loadAll().front;
		assert(node.isSequence);
		foreach (ref Node scalar; node) {
			assert(scalar.isScalar);
			assert(scalar.tag == correctTag);
		}
	}

	alias testGroup = AliasSeq!("bool", "float", "int", "merge", "null", "str", "timestamp", "value");
	run2!(testImplicitResolver, ["data", "detect"], testGroup)("Resolver");
}

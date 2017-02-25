//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.representer;

unittest {
	import std.array : array;
	import std.conv : text;
	import std.exception : enforce;
	import std.outbuffer : OutBuffer;
	import std.range : lockstep, StoppingPolicy;
	import std.typecons : AliasSeq;

	import wyaml.constructor : Constructor;
	import wyaml.dumper : Dumper;
	import wyaml.loader : Loader;
	import wyaml.node : Node;
	import wyaml.representer : Representer;
	import wyaml.tag : Tag;
	import wyaml.tests.common : run2, writeComparison;
	import wyaml.tests.constructor : constructClass, constructStruct, expected, representClass, representStruct, TestClass, TestStruct;

	/// Representer unittest.
	///
	/// Params: testName = Name of the test being run.
	void testRepresenterTypes(string testName) {
		enforce((testName in expected) !is null, new Exception("Unimplemented representer test: " ~ testName));

		Node[] expectedNodes = expected[testName];
		string output;
		Node[] readNodes;

		scope (failure) {
			writeComparison!("Expected nodes", "Read nodes", "Output")(testName, expectedNodes, readNodes, output);
		}

		auto emitStream = new OutBuffer;
		auto representer = new Representer;
		representer.addRepresenter!TestClass(&representClass);
		representer.addRepresenter!TestStruct(&representStruct);
		auto dumper = Dumper();
		dumper.representer = representer;
		dumper.dump(emitStream, expectedNodes);

		output = emitStream.text;
		auto constructor = new Constructor;
		constructor.addConstructorMapping!constructClass(Tag("!tag1"));
		constructor.addConstructorScalar!constructStruct(Tag("!tag2"));

		auto loader = Loader(emitStream.text);
		loader.name = "TEST";
		loader.constructor = constructor;
		readNodes = loader.loadAll().array;

		foreach (expected, read; lockstep(expectedNodes, readNodes, StoppingPolicy.requireSameLength)) {
			assert(expected == read);
		}
	}

	alias testGroup = AliasSeq!("aliases-cdumper-bug", "construct-binary", "construct-bool", "construct-custom", "construct-float", "construct-int", "construct-map", "construct-merge", "construct-null", "construct-omap", "construct-pairs", "construct-seq", "construct-set", "construct-str-ascii", "construct-str-utf8", "construct-str", "construct-timestamp", "construct-value", "duplicate-merge-key", "float-representer-2.3-bug", "invalid-single-quote-bug", "more-floats", "negative-float-bug", "single-dot-is-not-float-bug", "timestamp-bugs", "utf8");
	run2!(testRepresenterTypes, [], testGroup)("Representer");
}

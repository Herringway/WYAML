//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.representer;

unittest {
	import std.array;
	import std.conv;
	import std.exception;
	import std.meta;
	import std.outbuffer;
	import std.path;
	import std.range;
	import std.typecons;

	import wyaml.tests.common;
	import wyaml.tests.constructor;


	/// Representer unittest.
	///
	/// Params: testName = Name of the test being run.
	void testRepresenterTypes(string testName) {
		enforce((testName in wyaml.tests.constructor.expected) !is null,
				new Exception("Unimplemented representer test: " ~ testName));

		Node[] expectedNodes = expected[testName];
		string output;
		Node[] readNodes;

		scope(failure)
			writeComparison!("Expected nodes", "Read nodes", "Output")(testName, expectedNodes, readNodes, output);

		auto emitStream  = new OutBuffer;
		auto representer = new Representer;
		representer.addRepresenter!TestClass(&representClass);
		representer.addRepresenter!TestStruct(&representStruct);
		auto dumper = dumper(emitStream);
		dumper.representer = representer;
		dumper.dump(expectedNodes);

		output = emitStream.text;
		auto constructor = new Constructor;
		constructor.addConstructorMapping!constructClass("!tag1");
		constructor.addConstructorScalar!constructStruct("!tag2");

		auto loader        = Loader(emitStream.text);
		loader.name        = "TEST";
		loader.constructor = constructor;
		readNodes          = loader.loadAll().array;

		foreach(expected, read; lockstep(expectedNodes, readNodes, StoppingPolicy.requireSameLength))
			assert(expected == read);
	}

	alias testGroup = AliasSeq!( "aliases-cdumper-bug", "construct-binary", "construct-bool", "construct-custom", "construct-float", "construct-int", "construct-map", "construct-merge", "construct-null", "construct-omap", "construct-pairs", "construct-seq", "construct-set", "construct-str-ascii", "construct-str-utf8", "construct-str", "construct-timestamp", "construct-value", "duplicate-merge-key", "float-representer-2.3-bug", "invalid-single-quote-bug", "more-floats", "negative-float-bug", "single-dot-is-not-float-bug", "timestamp-bugs", "utf8");
	run2!(testRepresenterTypes, [], testGroup)("Representer");
}
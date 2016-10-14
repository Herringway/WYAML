//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.compare;

unittest {
	import std.meta : AliasSeq;
	import std.range : lockstep, StoppingPolicy;
	import wyaml.tests.common;
	import wyaml.token;

	/// Test parser by comparing output from parsing equivalent YAML data.
	///
	/// Params:  data              = YAML data to load.
	///          canonical         = Canonical YAML data.
	void testParser(string data, string canonical, string testName) {
		auto dataEvents = Loader(data).parse();
		auto canonicalEvents = Loader(canonical).parse();

		foreach (test, canon; lockstep(dataEvents, canonicalEvents, StoppingPolicy.requireSameLength)) {
			scope (failure)
				writeComparison(testName, canon, test);
			assert(test.id == canon.id, "testParser(" ~ testName ~ ") failed");
		}
	}

	/// Test loader by comparing output from loading equivalent YAML data.
	///
	/// Params:  data              = YAML data to load.
	///          canonical         = Canonical YAML data.
	void testLoader(string data, string canonical, string testName) {
		auto dataLoaded = Loader(data).loadAll();
		auto canonicalLoaded = Loader(canonical).loadAll();

		foreach (test, canon; lockstep(dataLoaded, canonicalLoaded, StoppingPolicy.requireSameLength)) {
			scope (failure)
				writeComparison(testName, canon, test);
			assert(test == canon, "testLoader(" ~ testName ~ ") failed");
		}
	}

	alias testSet = AliasSeq!("emit-block-scalar-in-simple-key-context-bug", "empty-document-bug", "scan-document-end-bug", "scan-line-break-bug", "sloppy-indentation", "spec-05-03", "spec-05-04",
		"spec-05-06", "spec-05-07", "spec-05-08", "spec-05-09", "spec-05-11", "spec-05-13", "spec-05-14", "spec-06-01", "spec-06-03", "spec-06-04", "spec-06-05", "spec-06-06", "spec-06-07",
		"spec-06-08", "spec-07-01", "spec-07-02", "spec-07-04", "spec-07-06", "spec-07-07a", "spec-07-07b", "spec-07-08", "spec-07-09", "spec-07-10", "spec-07-12a", "spec-07-12b", "spec-07-13",
		"spec-08-01", "spec-08-02", "spec-08-03", "spec-08-05", "spec-08-07", "spec-08-08", "spec-08-09", "spec-08-10", "spec-08-11", "spec-08-12", "spec-08-13", "spec-08-14", "spec-08-15",
		"spec-09-01", "spec-09-02", "spec-09-03", "spec-09-04", "spec-09-05", "spec-09-06", "spec-09-07", "spec-09-08", "spec-09-09", "spec-09-10", "spec-09-11", "spec-09-12", "spec-09-13",
		"spec-09-15", "spec-09-16", "spec-09-17", "spec-09-18", "spec-09-19", "spec-09-20", "spec-09-22", "spec-09-23", "spec-09-24", "spec-09-25", "spec-09-26", "spec-09-27", "spec-09-28",
		"spec-09-29", "spec-09-30", "spec-09-31", "spec-09-32", "spec-09-33", "spec-10-01", "spec-10-02", "spec-10-03", "spec-10-04", "spec-10-05", "spec-10-06", "spec-10-07", "spec-10-09",
		"spec-10-10", "spec-10-11", "spec-10-12", "spec-10-13", "spec-10-14", "spec-10-15");
	alias testSet2 = AliasSeq!("emit-block-scalar-in-simple-key-context-bug", "empty-document-bug", "scan-document-end-bug", "scan-line-break-bug", "sloppy-indentation", "spec-05-03", "spec-05-04",
		"spec-05-07", "spec-05-08", "spec-05-09", "spec-05-11", "spec-05-13", "spec-05-14", "spec-06-01", "spec-06-03", "spec-06-04", "spec-06-05", "spec-06-06", "spec-06-07", "spec-06-08",
		"spec-07-01", "spec-07-02", "spec-07-04", "spec-07-09", "spec-07-10", "spec-07-12a", "spec-07-12b", "spec-08-01", "spec-08-02", "spec-08-07", "spec-08-08", "spec-08-09", "spec-08-10",
		"spec-08-11", "spec-08-12", "spec-08-13", "spec-08-14", "spec-08-15", "spec-09-01", "spec-09-02", "spec-09-03", "spec-09-04", "spec-09-05", "spec-09-06", "spec-09-07", "spec-09-08",
		"spec-09-09", "spec-09-10", "spec-09-11", "spec-09-12", "spec-09-13", "spec-09-15", "spec-09-16", "spec-09-17", "spec-09-18", "spec-09-19", "spec-09-20", "spec-09-22", "spec-09-23",
		"spec-09-24", "spec-09-25", "spec-09-26", "spec-09-27", "spec-09-28", "spec-09-29", "spec-09-30", "spec-09-31", "spec-09-32", "spec-09-33", "spec-10-01", "spec-10-02", "spec-10-03",
		"spec-10-04", "spec-10-05", "spec-10-06", "spec-10-07", "spec-10-09", "spec-10-10", "spec-10-11", "spec-10-12", "spec-10-13", "spec-10-14", "spec-10-15");
	run2!(testParser, ["data", "canonical"], testSet)("Parser Comparison");
	run2!(testLoader, ["data", "canonical"], testSet2)("Loader Comparison");
}

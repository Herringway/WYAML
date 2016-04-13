
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.tokens;

unittest {
	import std.array;
	import std.meta;

	import wyaml.tests.common;
	import wyaml.token;
	/**
	 * Test tokens output by scanner.
	 *
	 * Params:  data   = Data to scan.
	 *          tokens = Data containing expected tokens.
	 */
	void testTokens(string data, string expected, string) {
		//representations of YAML tokens in tokens file.
		auto replace = [TokenID.Directive          : "%"   ,
						TokenID.DocumentStart      : "---" ,
						TokenID.DocumentEnd        : "..." ,
						TokenID.Alias              : "*"   ,
						TokenID.Anchor             : "&"   ,
						TokenID.Tag                : "!"   ,
						TokenID.Scalar             : "_"   ,
						TokenID.BlockSequenceStart : "[["  ,
						TokenID.BlockMappingStart  : "{{"  ,
						TokenID.BlockEnd           : "]}"  ,
						TokenID.FlowSequenceStart  : "["   ,
						TokenID.FlowSequenceEnd    : "]"   ,
						TokenID.FlowMappingStart   : "{"   ,
						TokenID.FlowMappingEnd     : "}"   ,
						TokenID.BlockEntry         : ","   ,
						TokenID.FlowEntry          : ","   ,
						TokenID.Key                : "?"   ,
						TokenID.Value              : ":"   ];

		string[] tokens1;
		auto tokens2 = expected.split();
		scope(exit) {
			version(verboseTest) {
				writeln("tokens1: ", tokens1, "\ntokens2: ", tokens2);
			}
		}

		auto loader = Loader(data);
		foreach(token; loader.scan()) {
			if(token.id != TokenID.StreamStart && token.id != TokenID.StreamEnd) {
				tokens1 ~= replace[token.id];
			}
		}

		assert(tokens1 == tokens2);
	}

	alias testGroup1 = AliasSeq!("spec-02-01", "spec-02-02", "spec-02-03", "spec-02-04", "spec-02-05", "spec-02-06", "spec-02-07", "spec-02-08", "spec-02-09", "spec-02-10", "spec-02-11", "spec-02-12", "spec-02-13", "spec-02-14", "spec-02-15", "spec-02-16", "spec-02-17", "spec-02-18", "spec-02-19", "spec-02-20", "spec-02-21", "spec-02-22", "spec-02-23", "spec-02-24", "spec-02-25", "spec-02-26", "spec-02-27", "spec-02-28");
	alias testGroup2 = AliasSeq!("emit-block-scalar-in-simple-key-context-bug", "empty-document-bug", "scan-document-end-bug", "scan-line-break-bug", "sloppy-indentation", "spec-05-03", "spec-05-04", "spec-05-06", "spec-05-07", "spec-05-08", "spec-05-09", "spec-05-11", "spec-05-13", "spec-05-14", "spec-06-01", "spec-06-03", "spec-06-04", "spec-06-05", "spec-06-06", "spec-06-07", "spec-06-08", "spec-07-01", "spec-07-02", "spec-07-04", "spec-07-06", "spec-07-07a", "spec-07-07b", "spec-07-08", "spec-07-09", "spec-07-10", "spec-07-12a", "spec-07-12b", "spec-07-13", "spec-08-01", "spec-08-02", "spec-08-03", "spec-08-05", "spec-08-07", "spec-08-08", "spec-08-09", "spec-08-10", "spec-08-11", "spec-08-12", "spec-08-13", "spec-08-14", "spec-08-15", "spec-09-01", "spec-09-02", "spec-09-03", "spec-09-04", "spec-09-05", "spec-09-06", "spec-09-07", "spec-09-08", "spec-09-09", "spec-09-10", "spec-09-11", "spec-09-12", "spec-09-13", "spec-09-15", "spec-09-16", "spec-09-17", "spec-09-18", "spec-09-19", "spec-09-20", "spec-09-22", "spec-09-23", "spec-09-24", "spec-09-25", "spec-09-26", "spec-09-27", "spec-09-28", "spec-09-29", "spec-09-30", "spec-09-31", "spec-09-32", "spec-09-33", "spec-10-01", "spec-10-02", "spec-10-03", "spec-10-04", "spec-10-05", "spec-10-06", "spec-10-07", "spec-10-09", "spec-10-10", "spec-10-11", "spec-10-12", "spec-10-13", "spec-10-14", "spec-10-15");
	/**
	 * Test scanner by scanning a file, expecting no errors.
	 *
	 * Params:  data      = Data to scan.
	 *          canonical = Canonical YAML data to scan.
	 */
	void testScanner(string data, string canonical, string) {
		foreach(yaml; [data, canonical]) {
			string[] tokens;
			scope(exit) {
				version(verboseTest) {writeln(tokens);}
			}
			auto loader = Loader(yaml);
			foreach(ref token; loader.scan()){tokens ~= to!string(token.id);}
		}
	}
	run2!(testTokens, ["data", "tokens"], testGroup1)("Tokens");
	run2!(testScanner, ["data", "canonical"], testGroup2)("Token Scanner");
}
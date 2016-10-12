//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.constructor;


version(unittest) {
	import std.conv : to, text;
	import std.datetime : DateTime, SysTime, SimpleTimeZone, dur, UTC;
	import std.exception : enforce;
	import std.meta : AliasSeq;
	import std.range : lockstep, StoppingPolicy;
	import std.string : format;
	import std.typecons : No;

	import wyaml.tag;
	import wyaml.tests.common;


	///Expected results of loading test inputs.
	Node[][string] expected;

	///Initialize expected.
	static this() {
		expected["aliases-cdumper-bug"]         = constructAliasesCDumperBug();
		expected["construct-binary"]            = constructBinary();
		expected["construct-bool"]              = constructBool();
		expected["construct-custom"]            = constructCustom();
		expected["construct-float"]             = constructFloat();
		expected["construct-int"]               = constructInt();
		expected["construct-map"]               = constructMap();
		expected["construct-merge"]             = constructMerge();
		expected["construct-null"]              = constructNull();
		expected["construct-omap"]              = constructOMap();
		expected["construct-pairs"]             = constructPairs();
		expected["construct-seq"]               = constructSeq();
		expected["construct-set"]               = constructSet();
		expected["construct-str-ascii"]         = constructStrASCII();
		expected["construct-str"]               = constructStr();
		expected["construct-str-utf8"]          = constructStrUTF8();
		expected["construct-timestamp"]         = constructTimestamp();
		expected["construct-value"]             = constructValue();
		expected["duplicate-merge-key"]         = duplicateMergeKey();
		expected["float-representer-2.3-bug"]   = floatRepresenterBug();
		expected["invalid-single-quote-bug"]    = invalidSingleQuoteBug();
		expected["more-floats"]                 = moreFloats();
		expected["negative-float-bug"]          = negativeFloatBug();
		expected["single-dot-is-not-float-bug"] = singleDotFloatBug();
		expected["timestamp-bugs"]              = timestampBugs();
		expected["utf8"]                        = utf8();
	}

	///Construct a pair of nodes with specified values.
	Node.Pair pair(A, B)(A a, B b) {
		return Node.Pair(a,b);
	}

	///Test cases:

	Node[] constructAliasesCDumperBug() {
		return [Node(["today", "today"])];
	}

	Node[] constructBinary() {
		auto canonical   = cast(ubyte[])"GIF89a\x0c\x00\x0c\x00\x84\x00\x00\xff\xff\xf7\xf5\xf5\xee\xe9\xe9\xe5fff\x00\x00\x00\xe7\xe7\xe7^^^\xf3\xf3\xed\x8e\x8e\x8e\xe0\xe0\xe0\x9f\x9f\x9f\x93\x93\x93\xa7\xa7\xa7\x9e\x9e\x9eiiiccc\xa3\xa3\xa3\x84\x84\x84\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9!\xfe\x0eMade with GIMP\x00,\x00\x00\x00\x00\x0c\x00\x0c\x00\x00\x05,  \x8e\x810\x9e\xe3@\x14\xe8i\x10\xc4\xd1\x8a\x08\x1c\xcf\x80M$z\xef\xff0\x85p\xb8\xb01f\r\x1b\xce\x01\xc3\x01\x1e\x10' \x82\n\x01\x00;";
		auto generic     = cast(ubyte[])"GIF89a\x0c\x00\x0c\x00\x84\x00\x00\xff\xff\xf7\xf5\xf5\xee\xe9\xe9\xe5fff\x00\x00\x00\xe7\xe7\xe7^^^\xf3\xf3\xed\x8e\x8e\x8e\xe0\xe0\xe0\x9f\x9f\x9f\x93\x93\x93\xa7\xa7\xa7\x9e\x9e\x9eiiiccc\xa3\xa3\xa3\x84\x84\x84\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9\xff\xfe\xf9!\xfe\x0eMade with GIMP\x00,\x00\x00\x00\x00\x0c\x00\x0c\x00\x00\x05,  \x8e\x810\x9e\xe3@\x14\xe8i\x10\xc4\xd1\x8a\x08\x1c\xcf\x80M$z\xef\xff0\x85p\xb8\xb01f\r\x1b\xce\x01\xc3\x01\x1e\x10' \x82\n\x01\x00;";
		auto description = "The binary value above is a tiny arrow encoded as a gif image.";

		return [Node([pair("canonical",   canonical),
					pair("generic",     generic),
					pair("description", description)])];
	}

	Node[] constructBool() {
		return [Node([pair("canonical", true),
				pair("answer",    false),
				pair("logical",   true),
				pair("option",    true),
				pair("but", [pair("y", "is a string"), pair("n", "is a string")])])];
	}

	Node[] constructCustom() {
		return [Node([Node(new TestClass(1, 2, 3)), Node(TestStruct(10))])];
	}

	Node[] constructFloat() {
		return [Node([pair("canonical",         cast(real)685230.15),
						pair("exponential",       cast(real)685230.15),
						pair("fixed",             cast(real)685230.15),
						pair("sexagesimal",       cast(real)685230.15),
						pair("negative infinity", -real.infinity),
						pair("not a number",      real.nan)])];
	}

	Node[] constructInt() {
		return [Node([pair("canonical",   685230L),
						pair("decimal",     685230L),
						pair("octal",       685230L),
						pair("hexadecimal", 685230L),
						pair("binary",      685230L),
						pair("sexagesimal", 685230L)])];
	}

	Node[] constructMap() {
		return [Node([pair("Block style",
					[pair("Clark", "Evans"),
					pair("Brian", "Ingerson"),
					pair("Oren", "Ben-Kiki")]),
				pair("Flow style",
					[pair("Clark", "Evans"),
					pair("Brian", "Ingerson"),
					pair("Oren", "Ben-Kiki")])])];
	}

	Node[] constructMerge() {
		return [Node([Node([pair("x", 1L), pair("y", 2L)]),
				Node([pair("x", 0L), pair("y", 2L)]),
				Node([pair("r", 10L)]),
				Node([pair("r", 1L)]),
				Node([pair("x", 1L), pair("y", 2L), pair("r", 10L), pair("label", "center/big")]),
				Node([pair("r", 10L), pair("label", "center/big"), pair("x", 1L), pair("y", 2L)]),
				Node([pair("label", "center/big"), pair("x", 1L), pair("y", 2L), pair("r", 10L)]),
				Node([pair("x", 1L), pair("label", "center/big"), pair("r", 10L), pair("y", 2L)])])];
	}

	Node[] constructNull() {
		return [Node(YAMLNull()),
				Node([pair("empty", YAMLNull()),
					pair("canonical", YAMLNull()),
					pair("english", YAMLNull()),
					pair(YAMLNull(), "null key")]),
				Node([pair("sparse",
					 [Node(YAMLNull()),
						Node("2nd entry"),
						Node(YAMLNull()),
						Node("4th entry"),
						Node(YAMLNull())])])];
	}

	Node[] constructOMap() {
		return [Node([pair("Bestiary",
				[pair("aardvark", "African pig-like ant eater. Ugly."),
				pair("anteater", "South-American ant eater. Two species."),
				pair("anaconda", "South-American constrictor snake. Scaly.")]),
				pair("Numbers",[pair("one", 1L),
				pair("two", 2L),
				pair("three", 3L)])])];
	}

	Node[] constructPairs() {
		return [Node([pair("Block tasks",
				Node([pair("meeting", "with team."),
				pair("meeting", "with boss."),
				pair("break", "lunch."),
				pair("meeting", "with client.")], "tag:yaml.org,2002:pairs")),
				pair("Flow tasks",
				Node([pair("meeting", "with team"),
				pair("meeting", "with boss")], "tag:yaml.org,2002:pairs"))])];
	}

	Node[] constructSeq() {
		return [Node([pair("Block style",
				[Node("Mercury"), Node("Venus"), Node("Earth"), Node("Mars"),
				Node("Jupiter"), Node("Saturn"), Node("Uranus"), Node("Neptune"),
				Node("Pluto")]),
				pair("Flow style",
				[Node("Mercury"), Node("Venus"), Node("Earth"), Node("Mars"),
				Node("Jupiter"), Node("Saturn"), Node("Uranus"), Node("Neptune"),
				Node("Pluto")])])];
	}

	Node[] constructSet() {
		return [Node([pair("baseball players",
				[Node("Mark McGwire"), Node("Sammy Sosa"), Node("Ken Griffey")]),
				pair("baseball teams",
				[Node("Boston Red Sox"), Node("Detroit Tigers"), Node("New York Yankees")])])];
	}

	Node[] constructStrASCII() {
		return [Node("ascii string")];
	}

	Node[] constructStr() {
		return [Node([pair("string", "abcd")])];
	}

	Node[] constructStrUTF8() {
		return [Node("\u042d\u0442\u043e \u0443\u043d\u0438\u043a\u043e\u0434\u043d\u0430\u044f \u0441\u0442\u0440\u043e\u043a\u0430")];
	}

	Node[] constructTimestamp() {
		alias DT = DateTime;
		alias ST = SysTime;
		return [Node([pair("canonical",        ST(DT(2001, 12, 15, 2, 59, 43), 1000000.dur!"hnsecs", UTC())),
						pair("valid iso8601",    ST(DT(2001, 12, 15, 2, 59, 43), 1000000.dur!"hnsecs", UTC())),
						pair("space separated",  ST(DT(2001, 12, 15, 2, 59, 43), 1000000.dur!"hnsecs", UTC())),
						pair("no time zone (Z)", ST(DT(2001, 12, 15, 2, 59, 43), 1000000.dur!"hnsecs", UTC())),
						pair("date (00:00:00Z)", ST(DT(2002, 12, 14), UTC()))])];
	}

	Node[] constructValue() {
		return[Node([pair("link with",
					[Node("library1.dll"), Node("library2.dll")])]),
					 Node([pair("link with",
					[Node([pair("=", "library1.dll"), pair("version", cast(real)1.2)]),
					 Node([pair("=", "library2.dll"), pair("version", cast(real)2.3)])])])];
	}

	Node[] duplicateMergeKey() {
		return [Node([pair("foo", "bar"),
					pair("x", 1L),
					pair("y", 2L),
					pair("z", 3L),
					pair("t", 4L)])];
	}

	Node[] floatRepresenterBug() {
		return [Node([pair(cast(real)1.0, 1L),
					pair(real.infinity, 10L),
					pair(-real.infinity, -10L),
					pair(real.nan, 100L)])];
	}

	Node[] invalidSingleQuoteBug() {
		return [Node([Node("foo \'bar\'"), Node("foo\n\'bar\'")])];
	}

	Node[] moreFloats() {
		return [Node([Node(cast(real)0.0),
				Node(cast(real)1.0),
				Node(cast(real)-1.0),
				Node(real.infinity),
				Node(-real.infinity),
				Node(real.nan),
				Node(real.nan)])];
	}

	Node[] negativeFloatBug() {
		return [Node(cast(real)-1.0)];
	}

	Node[] singleDotFloatBug() {
		return [Node(".")];
	}

	Node[] timestampBugs() {
		alias DT = DateTime;
		alias ST = SysTime;
		alias STZ = immutable SimpleTimeZone;
		return [Node([Node(ST(DT(2001, 12, 15, 3, 29, 43),  1000000.dur!"hnsecs", UTC())),
				Node(ST(DT(2001, 12, 14, 16, 29, 43), 1000000.dur!"hnsecs", UTC())),
				Node(ST(DT(2001, 12, 14, 21, 59, 43), 10100.dur!"hnsecs", UTC())),
				Node(ST(DT(2001, 12, 14, 21, 59, 43), new STZ(60.dur!"minutes"))),
				Node(ST(DT(2001, 12, 14, 21, 59, 43), new STZ(-90.dur!"minutes"))),
				Node(ST(DT(2005, 7, 8, 17, 35, 4),    5176000.dur!"hnsecs", UTC()))])];
	}

	Node[] utf8() {
		return [Node("UTF-8")];
	}

	///Testing custom YAML class type.
	class TestClass {
		int x, y, z;

		this(int x, int y, int z) {
			this.x = x;
			this.y = y;
			this.z = z;
		}

		//Any D:YAML type must have a custom opCmp operator.
		//This is used for ordering in mappings.
		override int opCmp(Object o) {
			TestClass s = cast(TestClass)o;
			if(s is null){return -1;}
			if(x != s.x){return x - s.x;}
			if(y != s.y){return y - s.y;}
			if(z != s.z){return z - s.z;}
			return 0;
		}

		void toString(scope void delegate(const(char)[]) sink) const {
			sink("TestClass(");
			sink(x.text);
			sink(", ");
			sink(y.text);
			sink(", ");
			sink(z.text);
			sink(")");
		}
	}

	///Testing custom YAML struct type.
	struct TestStruct {
		int value;

		//Any D:YAML type must have a custom opCmp operator.
		//This is used for ordering in mappings.
		const int opCmp(ref const TestStruct s) {
			return value - s.value;
		}
	}

	///Constructor function for TestClass.
	TestClass constructClass(ref Node node) {
		return new TestClass(node["x"].to!int, node["y"].to!int, node["z"].to!int);
	}

	Node representClass(ref Node node, Representer representer) {
		auto value = cast(TestClass)node;
		auto pairs = [Node.Pair("x", value.x),
						Node.Pair("y", value.y),
						Node.Pair("z", value.z)];
		auto result = representer.representMapping("!tag1", pairs);

		return result;
	}

	///Constructor function for TestStruct.
	TestStruct constructStruct(ref Node node) {
		return TestStruct(node.to!string.to!int);
	}

	///Representer function for TestStruct.
	Node representStruct(ref Node node, Representer representer) {
		string[] keys, values;
		auto value = node.to!TestStruct;
		return representer.representScalar("!tag2", value.value.to!string);
	}
}
unittest {
	/**
	 * Constructor unittest.
	 *
	 * Params:  dataFilename = File name to read from.
	 *          codeDummy    = Dummy .code filename, used to determine that
	 *                         .data file with the same name should be used in this test.
	 */
	void testConstructor(string data, string testName) {
		enforce((testName in expected) !is null,
			new Exception("Unimplemented constructor test: " ~ testName));

		auto constructor = new Constructor;
		constructor.addConstructorMapping!constructClass("!tag1");
		constructor.addConstructorScalar!constructStruct("!tag2");

		auto loader        = Loader(data);
		loader.constructor = constructor;
		loader.resolver    = new Resolver;

		Node[] exp = expected[testName];

		//Compare with expected results document by document.
		foreach(node, expected; lockstep(loader.loadAll(), exp, StoppingPolicy.requireSameLength))
		{
			scope(failure)
				writeComparison(testName, expected, node);
			assert(node == expected, testName ~ " failed");
		}
	}
	alias testSet = AliasSeq!("construct-binary", "construct-bool", "construct-custom", "construct-float", "construct-int", "construct-map", "construct-merge", "construct-null", "construct-omap", "construct-pairs", "construct-seq", "construct-set", "construct-str-ascii", "construct-str-utf8", "construct-str", "construct-timestamp", "construct-value", "duplicate-merge-key", "float-representer-2.3-bug", "invalid-single-quote-bug", "more-floats", "negative-float-bug", "single-dot-is-not-float-bug", "timestamp-bugs", "utf8");
	run2!(testConstructor, ["data"], testSet)("Constructor");
}
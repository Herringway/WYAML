//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * Class that processes YAML mappings, sequences and scalars into nodes. This can be
 * used to add custom data types. A tutorial can be found
 * $(LINK2 ../tutorials/custom_types.html, here).
 */
module wyaml.constructor;

import std.algorithm;
import std.array;
import std.base64;
import std.conv;
import std.datetime;
import std.exception;
import std.meta;
import std.range;
import std.regex;
import std.string;
import std.traits;
import std.typecons;
import std.utf;

import wyaml.exception;
import wyaml.node;
import wyaml.style;
import wyaml.tag;

// Exception thrown at constructor errors.
package class ConstructorException : YAMLException {
	/// Construct a ConstructorException.
	///
	/// Params:  msg   = Error message.
	///          start = Start position of the error context.
	///          end   = End position of the error context.
	this(string msg, string file = __FILE__, int line = __LINE__) @safe pure nothrow @nogc {
		super(msg, file, line);
	}
}

/** Constructs YAML values.
 *
 * Each YAML scalar, sequence or mapping has a tag specifying its data type.
 * Constructor uses user-specifyable functions to create a node of desired
 * data type from a scalar, sequence or mapping.
 *
 *
 * Each of these functions is associated with a tag, and can process either
 * a scalar, a sequence, or a mapping. The constructor passes each value to
 * the function with corresponding tag, which then returns the resulting value
 * that can be stored in a node.
 *
 * If a tag is detected with no known constructor function, it is considered an error.
 */
final class Constructor {
	// Constructor functions from scalars.
	private Node.Value function(ref Node)[Tag] fromScalar_;
	// Constructor functions from sequences.
	private Node.Value function(ref Node)[Tag] fromSequence_;
	// Constructor functions from mappings.
	private Node.Value function(ref Node)[Tag] fromMapping_;

	/// Construct a Constructor.
	///
	/// If you don't want to support default YAML tags/data types, you can use
	/// defaultConstructors to disable constructor functions for these.
	///
	/// Params:  defaultConstructors = Use constructors for default YAML tags?
	public this(const Flag!"useDefaultConstructors" defaultConstructors = Yes.useDefaultConstructors) @safe nothrow {
		if (!defaultConstructors) {
			return;
		}

		addConstructorScalar!constructNull(Tag("tag:yaml.org,2002:null"));
		addConstructorScalar!constructBool(Tag("tag:yaml.org,2002:bool"));
		addConstructorScalar!constructLong(Tag("tag:yaml.org,2002:int"));
		addConstructorScalar!constructReal(Tag("tag:yaml.org,2002:float"));
		addConstructorScalar!constructBinary(Tag("tag:yaml.org,2002:binary"));
		addConstructorScalar!constructTimestamp(Tag("tag:yaml.org,2002:timestamp"));
		addConstructorScalar!constructString(Tag("tag:yaml.org,2002:str"));

		///In a mapping, the default value is kept as an entry with the '=' key.
		addConstructorScalar!constructString(Tag("tag:yaml.org,2002:value"));

		addConstructorSequence!constructOrderedMap(Tag("tag:yaml.org,2002:omap"));
		addConstructorSequence!constructPairs(Tag("tag:yaml.org,2002:pairs"));
		addConstructorMapping!constructSet(Tag("tag:yaml.org,2002:set"));
		addConstructorSequence!constructSequence(Tag("tag:yaml.org,2002:seq"));
		addConstructorMapping!constructMap(Tag("tag:yaml.org,2002:map"));
		addConstructorScalar!constructMerge(Tag("tag:yaml.org,2002:merge"));
	}

	/** Add a constructor function from scalar.
	 *
	 * The function must take a reference to $(D Node) to construct from.
	 * The node contains a string for scalars, $(D Node[]) for sequences and
	 * $(D Node.Pair[]) for mappings.
	 *
	 * Any exception thrown by this function will be caught by D:YAML and
	 * its message will be added to a $(D YAMLException) that will also tell
	 * the user which type failed to construct, and position in the file.
	 *
	 *
	 * The value returned by this function will be stored in the resulting node.
	 *
	 * Only one constructor function can be set for one tag.
	 *
	 *
	 * Structs and classes must implement the $(D opCmp()) operator for D:YAML
	 * support. The signature of the operator that must be implemented
	 * is $(D const int opCmp(ref const MyStruct s)) for structs where
	 * $(I MyStruct) is the struct type, and $(D int opCmp(Object o)) for
	 * classes. Note that the class $(D opCmp()) should not alter the compared
	 * values - it is not const for compatibility reasons.
	 */
	public template addConstructorScalar(alias ctor) {
		alias addConstructorScalar = addConstructor!(string, ctor);
	}
	///
	unittest {
		import std.string;

		import wyaml;

		static struct MyStruct {
			int x, y, z;

			//Any D:YAML type must have a custom opCmp operator.
			//This is used for ordering in mappings.
			const int opCmp(ref const MyStruct s) {
				if (x != s.x) {
					return x - s.x;
				}
				if (y != s.y) {
					return y - s.y;
				}
				if(z != s.z) {
					return z - s.z;
				}
				return 0;
			}
		}

		static MyStruct constructMyStructScalar(ref Node node) {
			//Guaranteed to be string as we construct from scalar.
			//!mystruct x:y:z
			auto parts = node.to!string().split(":");
			// If this throws, the D:YAML will handle it and throw a YAMLException.
			return MyStruct(to!int(parts[0]), to!int(parts[1]), to!int(parts[2]));
		}

		auto loader = Loader("file.yaml");
		auto constructor = new Constructor;
		constructor.addConstructorScalar!constructMyStructScalar(Tag("!mystruct"));
		loader.constructor = constructor;
		Node node = loader.load();
	}

	/** Add a constructor function from sequence.
	 *
	 * See_Also:    addConstructorScalar
	 */
	public template addConstructorSequence(alias ctor) {
		alias addConstructorSequence = addConstructor!(Node[], ctor);
	}
	///
	unittest {
		import std.string;

		import wyaml;

		static struct MyStruct {
			int x, y, z;

			//Any D:YAML type must have a custom opCmp operator.
			//This is used for ordering in mappings.
			const int opCmp(ref const MyStruct s) {
				if(x != s.x) {
					return x - s.x;
				}
				if(y != s.y) {
					return y - s.y;
				}
				if(z != s.z) {
					return z - s.z;
				}
				return 0;
			}
		}

		static MyStruct constructMyStructSequence(ref Node node) {
			//node is guaranteed to be sequence.
			//!mystruct [x, y, z]
			return MyStruct(node[0].to!int, node[1].to!int, node[2].to!int);
		}

		auto loader = Loader("file.yaml");
		auto constructor = new Constructor;
		constructor.addConstructorSequence!constructMyStructSequence(Tag("!mystruct"));
		loader.constructor = constructor;
		Node node = loader.load();
	}

	/** Add a constructor function from a mapping.
	 *
	 * See_Also:    addConstructorScalar
	 */
	public template addConstructorMapping(alias ctor) {
		alias addConstructorMapping = addConstructor!(Node.Pair[], ctor);
	}
	///
	unittest {
		import std.string;

		import wyaml;

		static struct MyStruct {
			int x, y, z;

			//Any D:YAML type must have a custom opCmp operator.
			//This is used for ordering in mappings.
			const int opCmp(ref const MyStruct s) {
				if(x != s.x) {
					return x - s.x;
				}
				if(y != s.y) {
					return y - s.y;
				}
				if(z != s.z) {
					return z - s.z;
				}
				return 0;
			}
		}

		static MyStruct constructMyStructMapping(ref Node node) {
			//node is guaranteed to be mapping.
			//!mystruct {"x": x, "y": y, "z": z}
			return MyStruct(node["x"].to!int, node["y"].to!int, node["z"].to!int);
		}

		auto loader = Loader("file.yaml");
		auto constructor = new Constructor;
		constructor.addConstructorMapping!constructMyStructMapping(Tag("!mystruct"));
		loader.constructor = constructor;
		Node node = loader.load();
	}

	/*
	 * Construct a node.
	 *
	 * Params:  start = Start position of the node.
	 *          end   = End position of the node.
	 *          tag   = Tag (data type) of the node.
	 *          value = Value to construct node from (string, nodes or pairs).
	 *          style = Style of the node (scalar or collection style).
	 *
	 * Returns: Constructed node.
	 */
	package Node node(T, U)(const Mark start, const Mark end, const Tag tag, T value, U style) if ((is(T : string) || is(T == Node[]) || is(T == Node.Pair[])) && (is(U : CollectionStyle) || is(U : ScalarStyle))) {
		enum type = is(T : string) ? "scalar" :  is(T == Node[]) ? "sequence" :  is(T == Node.Pair[]) ? "mapping" : "ERROR";

		enforce((tag in delegateLocation!T) !is null, new ConstructorException("No constructor function from " ~ type ~ " for tag " ~ tag.get()));

		Node node = Node(value);
		static if (is(U : ScalarStyle)) {
			alias scalarStyle = style;
			alias collectionStyle = CollectionStyle.Invalid;
		} else static if (is(U : CollectionStyle)) {
			alias scalarStyle = ScalarStyle.Invalid;
			alias collectionStyle = style;
		} else
			static assert(false);
		return Node.rawNode(delegateLocation!T[tag](node), tag, scalarStyle, collectionStyle);
	}

	/*
	 * Add a constructor function.
	 *
	 * Params:  tag  = Tag for the function to handle.
	 *          ctor = Constructor function.
	 */
	private void addConstructor(T, alias ctor)(const Tag tag) @safe nothrow {
		assert((tag in fromScalar_) is null && (tag in fromSequence_) is null && (tag in fromMapping_) is null, "Constructor function for tag " ~ tag.get ~ " is already specified. Can't specify another one.");

		delegateLocation!T[tag] = (ref Node n) {
			static if (Node.allowed!(ReturnType!ctor)) {
				return Node.value(ctor(n));
			} else {
				return Node.userValue(ctor(n));
			}
		};
	}

	private template delegateLocation(T) {
		static if (is(T : string))
			alias delegateLocation = fromScalar_;
		else static if (is(T : Node[]))
			alias delegateLocation = fromSequence_;
		else static if (is(T : Node.Pair[]))
			alias delegateLocation = fromMapping_;
		else //Can't do anything with this type
			static assert(false);
	}
}

/// Construct a _null _node.
YAMLNull constructNull(ref Node node) @safe pure nothrow @nogc {
	return YAMLNull();
}

/// Construct a merge _node - a _node that merges another _node into a mapping.
YAMLMerge constructMerge(ref Node node) @safe pure nothrow @nogc {
	return YAMLMerge();
}

/// Construct a boolean _node.
bool constructBool(ref Node node) {
	alias yes = AliasSeq!("yes", "true", "on");
	alias no = AliasSeq!("no", "false", "off");
	string value = node.to!string().toLower();
	if (value.among(yes)) {
		return true;
	}
	if (value.among(no)) {
		return false;
	}
	throw new Exception("Unable to parse boolean value: " ~ value);
}

/// Construct an integer (long) _node.
long constructLong(ref Node node) {
	string value = node.to!string().replace("_", "");
	const char c = value[0];
	const long sign = c != '-' ? 1 : -1;
	if (c == '-' || c == '+') {
		value = value[1 .. $];
	}

	enforce(value != "", new Exception("Unable to parse float value: " ~ value));

	long result;
	try {
		//Zero.
		if (value == "0") {
			result = cast(long) 0;
		}  //Binary.
		else if (value.startsWith("0b")) {
			result = sign * to!int(value[2 .. $], 2);
		}  //Hexadecimal.
		else if (value.startsWith("0x")) {
			result = sign * to!int(value[2 .. $], 16);
		}  //Octal.
		else if (value[0] == '0') {
			result = sign * to!int(value, 8);
		}  //Sexagesimal.
		else if (value.canFind(":")) {
			long val = 0;
			long base = 1;
			foreach_reverse (digit; value.split(":")) {
				val += to!long(digit) * base;
				base *= 60;
			}
			result = sign * val;
		}  //Decimal.
		else {
			result = sign * to!long(value);
		}
	}
	catch (ConvException e) {
		throw new Exception("Unable to parse integer value: " ~ value);
	}

	return result;
}

unittest {
	long getLong(string str) {
		auto node = Node(str);
		return constructLong(node);
	}

	string canonical = "685230";
	string decimal = "+685_230";
	string octal = "02472256";
	string hexadecimal = "0x_0A_74_AE";
	string binary = "0b1010_0111_0100_1010_1110";
	string sexagesimal = "190:20:30";

	assert(getLong(canonical) == 685_230);
	assert(getLong(decimal) == 685_230);
	assert(getLong(octal) == 685_230);
	assert(getLong(hexadecimal) == 685_230);
	assert(getLong(binary) == 685_230);
	assert(getLong(sexagesimal) == 685_230);
}

/// Construct a floating point (real) _node.
real constructReal(ref Node node) {
	string value = node.to!string().replace("_", "").toLower();
	const char c = value[0];
	const real sign = c != '-' ? 1.0 : -1.0;
	if (c == '-' || c == '+') {
		value = value[1 .. $];
	}

	enforce(value != "" && value != "nan" && value != "inf" && value != "-inf", new Exception("Unable to parse float value: " ~ value));

	real result;
	try {
		//Infinity.
		if (value == ".inf") {
			result = sign * real.infinity;
		}  //Not a Number.
		else if (value == ".nan") {
			result = real.nan;
		}  //Sexagesimal.
		else if (value.canFind(":")) {
			real val = 0.0;
			real base = 1.0;
			foreach_reverse (digit; value.split(":")) {
				val += to!real(digit) * base;
				base *= 60.0;
			}
			result = sign * val;
		}  //Plain floating point.
		else {
			result = sign * to!real(value);
		}
	}
	catch (ConvException e) {
		throw new Exception("Unable to parse float value: \"" ~ value ~ "\"");
	}

	return result;
}

unittest {
	import std.math : isNaN, approxEqual;

	real getReal(string str) {
		auto node = Node(str);
		return constructReal(node);
	}

	string canonical = "6.8523015e+5";
	string exponential = "685.230_15e+03";
	string fixed = "685_230.15";
	string sexagesimal = "190:20:30.15";
	string negativeInf = "-.inf";
	string nan = ".NaN";

	assert(approxEqual(getReal(canonical), 685_230.15));
	assert(approxEqual(getReal(exponential), 685_230.15));
	assert(approxEqual(getReal(fixed), 685_230.15));
	assert(approxEqual(getReal(sexagesimal), 685_230.15));
	assert(approxEqual(getReal(negativeInf), -real.infinity));
	assert(getReal(nan).isNaN);
}

/// Construct a binary (base64) _node.
ubyte[] constructBinary(ref Node node) {
	string value = node.to!string;
	// For an unknown reason, this must be nested to work (compiler bug?).
	try {
		try {
			return Base64.decode(value.filter!(x => x != '\n').array);
		}
		catch (Exception e) {
			throw new Exception("Unable to decode base64 value: " ~ e.msg);
		}
	}
	catch (UTFException e) {
		throw new Exception("Unable to decode base64 value: " ~ e.msg);
	}
}

unittest {
	immutable(ubyte)[] test = "The Answer: 42".representation;
	char[] buffer;
	buffer.length = 256;
	string input = Base64.encode(test, buffer).idup;
	auto node = Node(input);
	const value = constructBinary(node);
	assert(value == test);
}

/// Construct a timestamp (SysTime) _node.
SysTime constructTimestamp(ref Node node) {
	string value = node.to!string;
	enum YMD = "^([0-9][0-9][0-9][0-9])-([0-9][0-9]?)-([0-9][0-9]?)";
	enum HMS = "^[Tt \t]+([0-9][0-9]?):([0-9][0-9]):([0-9][0-9])(\\.[0-9]*)?";
	enum TZ = "^[ \t]*Z|([-+][0-9][0-9]?)(:[0-9][0-9])?";
	version (release) {
		auto YMDRegexp = ctRegex!(YMD);
		auto HMSRegexp = ctRegex!(HMS);
		auto TZRegexp = ctRegex!(TZ);
	} else {
		auto YMDRegexp = regex(YMD);
		auto HMSRegexp = regex(HMS);
		auto TZRegexp = regex(TZ);
	}

	try {
		// First, get year, month and day.
		auto matches = match(value, YMDRegexp);

		enforce(!matches.empty, new Exception("Unable to parse timestamp value: " ~ value));

		auto captures = matches.front.captures;
		const year = to!int(captures[1]);
		const month = to!int(captures[2]);
		const day = to!int(captures[3]);

		// If available, get hour, minute, second and fraction, if present.
		value = matches.front.post;
		matches = match(value, HMSRegexp);
		if (matches.empty) {
			return SysTime(DateTime(year, month, day), UTC());
		}

		captures = matches.front.captures;
		const hour = to!int(captures[1]);
		const minute = to!int(captures[2]);
		const second = to!int(captures[3]);
		const hectonanosecond = cast(int)(to!real("0" ~ captures[4]) * 10_000_000);

		// If available, get timezone.
		value = matches.front.post;
		matches = match(value, TZRegexp);
		if (matches.empty || matches.front.captures[0] == "Z") {
			// No timezone.
			return SysTime(DateTime(year, month, day, hour, minute, second), hectonanosecond.dur!"hnsecs", UTC());
		}

		// We have a timezone, so parse it.
		captures = matches.front.captures;
		int sign = 1;
		int tzHours = 0;
		if (!captures[1].empty) {
			if (captures[1][0] == '-') {
				sign = -1;
			}
			tzHours = to!int(captures[1][1 .. $]);
		}
		const tzMinutes = (!captures[2].empty) ? to!int(captures[2][1 .. $]) : 0;
		const tzOffset = dur!"minutes"(sign * (60 * tzHours + tzMinutes));

		return SysTime(DateTime(year, month, day, hour, minute, second), hectonanosecond.dur!"hnsecs", new immutable SimpleTimeZone(tzOffset));
	}
	catch (ConvException e) {
		throw new Exception("Unable to parse timestamp value " ~ value ~ " : " ~ e.msg);
	}
	catch (DateTimeException e) {
		throw new Exception("Invalid timestamp value " ~ value ~ " : " ~ e.msg);
	}

	assert(false, "This code should never be reached");
}
///
unittest {
	string timestamp(string value) {
		auto node = Node(value);
		return constructTimestamp(node).toISOString();
	}

	string canonical = "2001-12-15T02:59:43.1Z";
	string iso8601 = "2001-12-14t21:59:43.10-05:00";
	string spaceSeparated = "2001-12-14 21:59:43.10 -5";
	string noTZ = "2001-12-15 2:59:43.10";
	string noFraction = "2001-12-15 2:59:43";
	string ymd = "2002-12-14";

	assert(timestamp(canonical) == "20011215T025943.1Z");
	//avoiding float conversion errors
	assert(timestamp(iso8601) == "20011214T215943.0999999-05:00" || timestamp(iso8601) == "20011214T215943.1-05:00");
	assert(timestamp(spaceSeparated) == "20011214T215943.0999999-05:00" || timestamp(spaceSeparated) == "20011214T215943.1-05:00");
	assert(timestamp(noTZ) == "20011215T025943.0999999Z" || timestamp(noTZ) == "20011215T025943.1Z");
	assert(timestamp(noFraction) == "20011215T025943Z");
	assert(timestamp(ymd) == "20021214T000000Z");
}

/// Construct a string _node.
string constructString(ref Node node) {
	return node.to!string;
}

/// Convert a sequence of single-element mappings into a sequence of pairs.
Node.Pair[] getPairs(string type, Node[] nodes) {
	Node.Pair[] pairs;

	foreach (ref node; nodes) {
		enforce(node.isMapping && node.length == 1, new Exception("While constructing " ~ type ~ ", expected a mapping with single element"));

		pairs.assumeSafeAppend();
		pairs ~= node.to!(Node.Pair[]);
	}

	return pairs;
}

/// Construct an ordered map (ordered sequence of key:value pairs without duplicates) _node.
Node.Pair[] constructOrderedMap(ref Node node) {
	auto pairs = getPairs("ordered map", node.to!(Node[]));
	enforce(!pairs.hasDuplicates, new Exception("Found duplicate entry in an ordered map"));
	return pairs;
}

unittest {
	Node[] alternateTypes(uint length) {
		Node[] pairs;
		foreach (long i; 0 .. length) {
			auto pair = (i % 2) ? Node.Pair(i.to!string, i) : Node.Pair(i, i.to!string);
			pairs.assumeSafeAppend();
			pairs ~= Node([pair]);
		}
		return pairs;
	}

	Node[] sameType(uint length) {
		Node[] pairs;
		foreach (long i; 0 .. length) {
			auto pair = Node.Pair(i.to!string, i);
			pairs.assumeSafeAppend();
			pairs ~= Node([pair]);
		}
		return pairs;
	}

	bool hasDuplicates(Node[] nodes) {
		auto node = Node(nodes);
		return null !is collectException(constructOrderedMap(node));
	}

	assert(hasDuplicates(alternateTypes(8) ~ alternateTypes(2)));
	assert(!hasDuplicates(alternateTypes(8)));
	assert(hasDuplicates(sameType(64) ~ sameType(16)));
	assert(hasDuplicates(alternateTypes(64) ~ alternateTypes(16)));
	assert(!hasDuplicates(sameType(64)));
	assert(!hasDuplicates(alternateTypes(64)));
}

/// Construct a pairs (ordered sequence of key: value pairs allowing duplicates) _node.
Node.Pair[] constructPairs(ref Node node) {
	return getPairs("pairs", node.to!(Node[]));
}

/// Construct a set _node.
Node[] constructSet(ref Node node) {
	auto pairs = node.to!(Node.Pair[]);
	enforce(!pairs.hasDuplicates, new Exception("Found duplicate entry in an ordered map"));
	return pairs.map!(x => x.key).array;
}

unittest {
	Node.Pair[] set(uint length) {
		Node.Pair[] pairs;
		foreach (long i; 0 .. length) {
			pairs.assumeSafeAppend();
			pairs ~= Node.Pair(i.to!string, YAMLNull());
		}

		return pairs;
	}

	auto duplicatesShort = set(8) ~ set(2);
	auto noDuplicatesShort = set(8);
	auto duplicatesLong = set(64) ~ set(4);
	auto noDuplicatesLong = set(64);

	bool eq(Node.Pair[] a, Node[] b) {
		if (a.length != b.length) {
			return false;
		}
		foreach (i; 0 .. a.length) {
			if (a[i].key != b[i]) {
				return false;
			}
		}
		return true;
	}

	auto nodeDuplicatesShort = Node(duplicatesShort);
	auto nodeNoDuplicatesShort = Node(noDuplicatesShort);
	auto nodeDuplicatesLong = Node(duplicatesLong);
	auto nodeNoDuplicatesLong = Node(noDuplicatesLong);

	assert(collectException(constructSet(nodeDuplicatesShort)) !is null);
	assert(collectException(constructSet(nodeNoDuplicatesShort)) is null);
	assert(collectException(constructSet(nodeDuplicatesLong)) !is null);
	assert(collectException(constructSet(nodeNoDuplicatesLong)) is null);
}

/// Construct a sequence (array) _node.
Node[] constructSequence(ref Node node) {
	return node.to!(Node[]);
}

/// Construct an unordered map (unordered set of key:value _pairs without duplicates) _node.
Node.Pair[] constructMap(ref Node node) {
	auto pairs = node.to!(Node.Pair[]);
	enforce(!pairs.hasDuplicates, new Exception("Found duplicate entry in an ordered map"));
	return pairs;
}

// Unittests

import wyaml.loader;

version (unittest) {
	struct MyStruct {
		int x, y, z;

		int opCmp(ref const MyStruct s) const pure @safe nothrow {
			if (x != s.x) {
				return x - s.x;
			}
			if (y != s.y) {
				return y - s.y;
			}
			if (z != s.z) {
				return z - s.z;
			}
			return 0;
		}

		bool opEquals(const MyStruct b) const pure @safe nothrow {
			return x == b.x && y == b.y && z == b.z;
		}

		size_t toHash() const pure nothrow {
			auto hash = hashOf(x);
			hash = hashOf(y, hash);
			hash = hashOf(z, hash);
			return hash;
		}
	}

	MyStruct constructMyStructScalar(ref Node node) {
		// Guaranteed to be string as we construct from scalar.
		auto parts = node.to!string().split(":");
		return MyStruct(to!int(parts[0]), to!int(parts[1]), to!int(parts[2]));
	}

	MyStruct constructMyStructSequence(ref Node node) {
		// node is guaranteed to be sequence.
		return MyStruct(node[0].to!int, node[1].to!int, node[2].to!int);
	}

	MyStruct constructMyStructMapping(ref Node node) {
		// node is guaranteed to be mapping.
		return MyStruct(node["x"].to!int, node["y"].to!int, node["z"].to!int);
	}
}
unittest {
	string data = "!mystruct 1:2:3";
	auto loader = Loader(data);
	auto constructor = new Constructor;
	constructor.addConstructorScalar!constructMyStructScalar(Tag("!mystruct"));
	loader.constructor = constructor;
	immutable node = loader.loadAll().front;

	assert(node.to!MyStruct == MyStruct(1, 2, 3));
}

unittest {
	string data = "!mystruct [1, 2, 3]";
	auto loader = Loader(data);
	auto constructor = new Constructor;
	constructor.addConstructorSequence!constructMyStructSequence(Tag("!mystruct"));
	loader.constructor = constructor;
	immutable node = loader.loadAll().front;

	assert(node.to!MyStruct == MyStruct(1, 2, 3));
}

unittest {
	string data = "!mystruct {x: 1, y: 2, z: 3}";
	auto loader = Loader(data);
	auto constructor = new Constructor;
	constructor.addConstructorMapping!constructMyStructMapping(Tag("!mystruct"));
	loader.constructor = constructor;
	immutable node = loader.loadAll().front;

	assert(node.to!MyStruct == MyStruct(1, 2, 3));
}

//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Node of a YAML document. Used to read YAML data once it's loaded,
/// and to prepare data to emit.
module wyaml.node;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.format;
import std.math;
import std.range;
import std.traits;
import std.typecons;
import std.variant;

import wyaml.event;
import wyaml.exception;
import wyaml.style;
import wyaml.tag;

/// Exception thrown at node related errors.
class NodeException : YAMLException {
	// Construct a NodeException.
	//
	// Params:  msg   = Error message.
	//          start = Start position of the node.
	package this(string msg, Mark start, string file = __FILE__, int line = __LINE__) @safe pure {
		super(msg ~ "\nNode at: " ~ start.text, file, line);
	}
}

// Node kinds.
package enum NodeID : ubyte {
	Scalar,
	Sequence,
	Mapping
}

/// Null YAML type. Used in nodes with _null values.
struct YAMLNull {
	/// Used for string conversion.
	string toString() const pure @safe nothrow {
		return "null";
	}
}

// Merge YAML type, used to support "tag:yaml.org,2002:merge".
package struct YAMLMerge {
}

// Base class for YAMLContainer - used for user defined YAML types.
package interface YAMLObject {
	// Get type of the stored value.
	public @property TypeInfo type() const pure @safe nothrow;
	// Compare with another YAMLObject.
	protected int cmp(const YAMLObject rhs) const @system;
}

// Stores a user defined YAML data type.
package final class YAMLContainer(T) if (!Node.allowed!T)
	 : YAMLObject {
	// Stored value.
	private T value_;

	// Get type of the stored value.
	public override TypeInfo type() const pure @safe nothrow {
		return typeid(T);
	}

	// Get string representation of the container.
	public void toString(T)(T sink) const if (isOutputRange!(T, string)) {
		formattedWrite(sink, "YAMLContainer(%s)", value_);
	}

	// Compare with another YAMLObject.
	protected override int cmp(const YAMLObject rhs) const @system {
		const typeCmp = type.opCmp(rhs.type);
		if (typeCmp != 0) {
			return typeCmp;
		}

		// Const-casting here as Object opCmp is not const.
		T* v1 = cast(T*)&value_;
		T* v2 = cast(T*)&((cast(YAMLContainer) rhs).value_);
		return (*v1).opCmp(*v2);
	}

	// Construct a YAMLContainer holding specified value.
	private this(T value) {
		value_ = value;
	}
}

@safe unittest {
	struct Test {
		string toString() const {
			return "test";
		}

		int opCmp(Test) const {
			return 1;
		}

		bool opEquals(Test) const {
			return false;
		}

		auto toHash() const {
			return hashOf(0);
		}
	}

	immutable t = new YAMLContainer!Test(Test());
	assert(t.text == "YAMLContainer(test)");
}

///Test for duplicate keys
bool hasDuplicates(Node.Pair[] nodes) {
	auto index = new size_t[nodes.length];
	makeIndex!((x,y) => x.key < y.key)(nodes, index);
	return indexed(nodes, index).uniq.walkLength != nodes.length;
}

// Key-value pair of YAML nodes, used in mappings.
private struct Pair {
	/// Key node.
	public Node key;
	/// Value node.
	public Node value;

	/// Construct a Pair from two values. Will be converted to Nodes if needed.
	public this(K, V)(K key, V value) {
		static if (is(Unqual!K == Node)) {
			this.key = key;
		} else {
			this.key = Node(key);
		}
		static if (is(Unqual!V == Node)) {
			this.value = value;
		} else {
			this.value = Node(value);
		}
	}

	/// Equality test with another Pair.
	public bool opEquals(const ref Pair rhs) const @safe {
		return cmp(rhs) == 0;
	}

	/// Assignment (shallow copy) by value.
	public void opAssign(Pair rhs) @safe nothrow {
		opAssign(rhs);
	}

	/// Assignment (shallow copy) by reference.
	public void opAssign(ref Pair rhs) @safe nothrow {
		key = rhs.key;
		value = rhs.value;
	}

	// Comparison with another Pair.
	//
	// useTag determines whether or not we consider node tags
	// in the comparison.
	private int cmp(ref const(Pair) rhs) const @safe {
		const keyCmp = key.cmp(rhs.key);
		return keyCmp != 0 ? keyCmp : value.cmp(rhs.value);
	}

	@disable int opCmp(ref Pair) const;
}

/** YAML node.
 *
 * This is a pseudo-dynamic type that can store any YAML value, including a
 * sequence or mapping of nodes. You can get data from a Node directly or
 * iterate over it if it's a collection.
 */
struct Node {
	public alias Pair = .Pair;

	// YAML value type.
	package alias Value = Algebraic!(YAMLNull, YAMLMerge, bool, long, real, ubyte[], SysTime, string, Node.Pair[], Node[], YAMLObject);

	// Can Value hold this type without wrapping it in a YAMLObject?
	package template allowed(T) {
		enum allowed = isIntegral!T || isFloatingPoint!T || isSomeString!T || Value.allowed!T;
	}

	// Stored value.
	private Value value_;
	// Start position of the node.
	private Mark startMark_;

	// Tag of the node.
	package Tag tag_;
	// Node scalar style. Used to remember style this node was loaded with.
	package ScalarStyle scalarStyle = ScalarStyle.Invalid;
	// Node collection style. Used to remember style this node was loaded with.
	package CollectionStyle collectionStyle = CollectionStyle.Invalid;

	// If scalarCtorNothrow!T is true, scalar node ctor from T can be nothrow.
	//
	// TODO
	// Eventually we should simplify this and make all Node constructors except from
	// user values nothrow (and think even about those user values). 2014-08-28
	package enum scalarCtorNothrow(T) = (is(Unqual!T == string) || isIntegral!T || isFloatingPoint!T) || (Value.allowed!T && (!is(Unqual!T == Value) && !isSomeString!T && !isArray!T && !isAssociativeArray!T));

	/** Construct a Node from a value.
	 *
	 * Any type except for Node can be stored in a Node, but default YAML
	 * types (integers, floats, strings, timestamps, etc.) will be stored
	 * more efficiently. To create a node representing a null value,
	 * construct it from YAMLNull.
	 *
	 *
	 * Note that to emit any non-default types you store
	 * in a node, you need a Representer to represent them in YAML -
	 * otherwise emitting will fail.
	 *
	 * Params:  value = Value to store in the node.
	 *          tag   = Overrides tag of the node when emitted, regardless
	 *                  of tag determined by Representer. Representer uses
	 *                  this to determine YAML data type when a D data type
	 *                  maps to multiple different YAML data types. Tag must
	 *                  be in full form, e.g. "tag:yaml.org,2002:int", not
	 *                  a shortcut, like "!!int".
	 */
	public this(T)(T value, const string tag = null) if ((isSomeString!T || !isArray!T) && !isAssociativeArray!T && !is(Unqual!T == Node)) {
		tag_ = Tag(tag);

		static if (isSomeString!T) {
			value_ = Value(value.to!string);
		} else static if (isIntegral!T) {
			value_ = Value(cast(long) value);
		} else static if (isFloatingPoint!T) {
			value_ = Value(cast(real) value);
		} else static if (is(Unqual!T == Value)) {
			value_ = Value(value);
		} else static if (Value.allowed!T) {
			value_ = Value(value);
		} else { // User defined type.
			value_ = userValue(value);
		}
	}

	/** Construct a node from an _array.
	 *
	 * If _array is an _array of nodes or pairs, it is stored directly.
	 * Otherwise, every value in the array is converted to a node, and
	 * those nodes are stored.
	 *
	 * Params:  array = Values to store in the node.
	 *          tag   = Overrides tag of the node when emitted, regardless
	 *                  of tag determined by Representer. Representer uses
	 *                  this to determine YAML data type when a D data type
	 *                  maps to multiple different YAML data types.
	 *                  This is used to differentiate between YAML sequences
	 *                  ("!!seq") and sets ("!!set"), which both are
	 *                  internally represented as an array_ of nodes. Tag
	 *                  must be in full form, e.g. "tag:yaml.org,2002:set",
	 *                  not a shortcut, like "!!set".
	 *
	 * Examples:
	 * --------------------
	 * // Will be emitted as a sequence (default for arrays)
	 * auto seq = Node([1, 2, 3, 4, 5]);
	 * // Will be emitted as a set (overriden tag)
	 * auto set = Node([1, 2, 3, 4, 5], "tag:yaml.org,2002:set");
	 * --------------------
	 */
	public this(T)(T[] array, const string tag = null) if (!isSomeString!(T[])) {
		tag_ = Tag(tag);

		// Construction from raw node or pair array.
		static if (is(Unqual!T == Node) || is(Unqual!T == Node.Pair)) {
			value_ = Value(array);
		} else static if (is(Unqual!T == byte) || is(Unqual!T == ubyte)) { // Need to handle byte buffers separately.
			value_ = Value(cast(ubyte[]) array);
		} else {
			Node[] nodes;
			foreach (ref value; array) {
				nodes ~= Node(value);
			}
			value_ = Value(nodes);
		}
	}

	/** Construct a node from an associative _array.
	 *
	 * If keys and/or values of _array are nodes, they stored directly.
	 * Otherwise they are converted to nodes and then stored.
	 *
	 * Params:  array = Values to store in the node.
	 *          tag   = Overrides tag of the node when emitted, regardless
	 *                  of tag determined by Representer. Representer uses
	 *                  this to determine YAML data type when a D data type
	 *                  maps to multiple different YAML data types.
	 *                  This is used to differentiate between YAML unordered
	 *                  mappings ("!!map"), ordered mappings ("!!omap"), and
	 *                  pairs ("!!pairs") which are all internally
	 *                  represented as an _array of node pairs. Tag must be
	 *                  in full form, e.g. "tag:yaml.org,2002:omap", not a
	 *                  shortcut, like "!!omap".
	 *
	 * Examples:
	 * --------------------
	 * // Will be emitted as an unordered mapping (default for mappings)
	 * auto map   = Node([1 : "a", 2 : "b"]);
	 * // Will be emitted as an ordered map (overriden tag)
	 * auto omap  = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:omap");
	 * // Will be emitted as pairs (overriden tag)
	 * auto pairs = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:pairs");
	 * --------------------
	 */
	public this(K, V)(V[K] array, const string tag = null) {
		tag_ = Tag(tag);

		Node.Pair[] pairs;
		foreach (key, ref value; array) {
			pairs ~= Pair(key, value);
		}
		value_ = Value(pairs);
	}

	/** Construct a node from arrays of _keys and _values.
	 *
	 * Constructs a mapping node with key-value pairs from
	 * _keys and _values, keeping their order. Useful when order
	 * is important (ordered maps, pairs).
	 *
	 *
	 * keys and values must have equal length.
	 *
	 *
	 * If _keys and/or _values are nodes, they are stored directly/
	 * Otherwise they are converted to nodes and then stored.
	 *
	 * Params:  keys   = Keys of the mapping, from first to last pair.
	 *          values = Values of the mapping, from first to last pair.
	 *          tag    = Overrides tag of the node when emitted, regardless
	 *                   of tag determined by Representer. Representer uses
	 *                   this to determine YAML data type when a D data type
	 *                   maps to multiple different YAML data types.
	 *                   This is used to differentiate between YAML unordered
	 *                   mappings ("!!map"), ordered mappings ("!!omap"), and
	 *                   pairs ("!!pairs") which are all internally
	 *                   represented as an array of node pairs. Tag must be
	 *                   in full form, e.g. "tag:yaml.org,2002:omap", not a
	 *                   shortcut, like "!!omap".
	 *
	 * Examples:
	 * --------------------
	 * // Will be emitted as an unordered mapping (default for mappings)
	 * auto map   = Node([1, 2], ["a", "b"]);
	 * // Will be emitted as an ordered map (overriden tag)
	 * auto omap  = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:omap");
	 * // Will be emitted as pairs (overriden tag)
	 * auto pairs = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:pairs");
	 * --------------------
	 */
	public this(K, V)(K[] keys, V[] values, const string tag = null) if (!(isSomeString!(K[]) || isSomeString!(V[])))
	in {
		assert(keys.length == values.length, "Lengths of keys and values arrays to construct a YAML node from don't match");
	}
	body {
		tag_ = Tag(tag);

		Node.Pair[] pairs;
		foreach (i; 0 .. keys.length) {
			pairs ~= Pair(keys[i], values[i]);
		}
		value_ = Value(pairs);
	}

	/// Is this node valid (initialized)?
	public bool isValid() const @safe pure nothrow {
		return value_.hasValue;
	}

	/// Is this node a scalar value?
	public bool isScalar() const @safe nothrow {
		return !(isMapping || isSequence);
	}

	/// Is this node a sequence?
	public bool isSequence() const @safe nothrow {
		return isType!(Node[]);
	}

	/// Is this node a mapping?
	public bool isMapping() const @safe nothrow {
		return isType!(Pair[]);
	}

	/// Is this node a user defined type?
	public bool isUserType() const @safe nothrow {
		return isType!YAMLObject;
	}

	/// Is this node null?
	public bool isNull() const @safe nothrow {
		return isType!YAMLNull;
	}

	/// Return tag of the node.
	public string tag() const @safe nothrow {
		return tag_.get;
	}

	/** Equality test.
	 *
	 * If T is Node, recursively compares all subnodes.
	 * This might be quite expensive if testing entire documents.
	 *
	 * If T is not Node, gets a value of type T from the node and tests
	 * equality with that.
	 *
	 * To test equality with a null YAML value, use YAMLNull.
	 *
	 * Params:  rhs = Variable to test equality with.
	 *
	 * Returns: true if equal, false otherwise.
	 */
	public bool opEquals(T)(const auto ref T rhs) const {
		static if (is(Unqual!T == Node)) {
			return cmp(rhs) == 0;
		} else {
			try {
				static if (isSomeString!T) {
					auto stored = toString!(const(Unqual!T), No.stringConversion);
				} else {
					auto stored = cast(const(Unqual!T)) this;
				}
				// Need to handle NaNs separately.
				static if (isFloatingPoint!T) {
					return rhs == stored || (isNaN(rhs) && isNaN(stored));
				} else {
					return rhs == cast(const(Unqual!T)) this;
				}
			}
			catch (NodeException e) {
				return false;
			}
		}
	}

	public T opCast(T)() const {
		if (isType!(Unqual!T))
			return cast(T) value_.get!T;

		/// Must go before others, as even string/int/etc could be stored in a YAMLObject.
		static if (!allowed!(Unqual!T))
			if (isUserType) {
				auto object = cast(YAMLObject) this;
				if (object.type is typeid(T)) {
					return (cast(YAMLContainer!(Unqual!T)) object).value_;
				}
				throw new NodeException("Node has unexpected type: " ~ object.type.text ~ ". Expected: " ~ typeid(T).text, startMark_);
			}

		// If we're getting from a mapping and we're not getting Node.Pair[],
		// we're getting the default value.
		if (isMapping)
			return cast(T) this["="];

		static if (isSomeString!T) {
			return toString!T;
		} else static if (isFloatingPoint!T) {
			/// Can convert int to float.
			if (isInt()) {
				return cast(T)(value_.get!(const long));
			} else if (isFloat()) {
				return cast(T)(value_.get!(const real));
			} else {
				throw new NodeException("Unable to convert node value to floating point", startMark_);
			}
		} else static if (isIntegral!T) {
			enforce(isInt(), new NodeException("Unable to convert node value to integer", startMark_));
			const temp = value_.get!(const long);
			enforce(temp >= T.min && temp <= T.max, new NodeException("Integer value of type " ~ typeid(T).text ~ " out of range. Value: " ~ to!string(temp), startMark_));
			return temp.to!T;
		} else
			assert(0, "Cannot cast to this type");
	}

	public T toString(T = string, Flag!"stringConversion" stringConversion = Yes.stringConversion)() const if (isSomeString!T) {
		static if (!stringConversion) {
			if (isString)
				return value_.get!string.to!T;
			throw new NodeException("Node stores unexpected type: " ~ type.text ~ ". Expected: " ~ typeid(T).text, startMark_);
		} else {
			try { //Variant does not support const coercing?
				return (cast() value_).coerce!T;
			}
			catch (VariantException e) {
				throw new NodeException("Unable to convert node value to string", startMark_);
			}
		}
	}
	/** If this is a collection, return its _length.
	 *
	 * Otherwise, throw NodeException.
	 *
	 * Returns: Number of elements in a sequence or key-value pairs in a mapping.
	 *
	 * Throws: NodeException if this is not a sequence nor a mapping.
	 */
	public size_t length() const {
		if (isSequence) {
			return value_.get!(const Node[]).length;
		} else if (isMapping) {
			return value_.get!(const Pair[]).length;
		}
		throw new NodeException("Trying to get length of a " ~ nodeTypeString ~ " node", startMark_);
	}

	public alias opDollar = length;

	/** Get the element at specified index.
	 *
	 * If the node is a sequence, index must be integral.
	 *
	 *
	 * If the node is a mapping, return the value corresponding to the first
	 * key equal to index. The in operator can be used to determine if a mapping
	 * has a specific key.
	 *
	 * To get element at a null index, use YAMLNull for index.
	 *
	 * Params:  index = Index to use.
	 *
	 * Returns: Value corresponding to the index.
	 *
	 * Throws:  NodeException if the index could not be found,
	 *          non-integral index is used with a sequence or the node is
	 *          not a collection.
	 */
	public ref Node opIndex(T)(T index) {
		if (isSequence) {
			checkSequenceIndex(index);
			static if (isIntegral!T) {
				return cast(Node) value_.get!(Node[])[index];
			}
			assert(false);
		} else if (isMapping) {
			auto idx = findPair(index);
			if (idx >= 0) {
				return cast(Node) value_.get!(Pair[])[idx].value;
			}

			throw new NodeException("Mapping index not found" ~ (isSomeString!T ? ": " ~ to!string(index) : ""), startMark_);
		}
		throw new NodeException("Trying to index a " ~ nodeTypeString ~ " node", startMark_);
	}

	/** Determine if a collection contains specified value.
	 *
	 * If the node is a sequence, check if it contains the specified value.
	 * If it's a mapping, check if it has a value that matches specified value.
	 *
	 * Params:  rhs = Item to look for. Use YAMLNull to check for a null value.
	 *
	 * Returns: true if rhs was found, false otherwise.
	 *
	 * Throws:  NodeException if the node is not a collection.
	 */
	public bool contains(T)(T rhs) const @trusted {
		if (isSequence)
			return (cast(Node[]) this).canFind(Node(rhs));

		if (isMapping)
			return findPair!(T, No.key)(rhs) >= 0;

		throw new NodeException("Trying to use contains() on a " ~ nodeTypeString ~ " node", startMark_);
	}

	/// Assignment (shallow copy) by value.
	public void opAssign(Node rhs) @safe nothrow {
		opAssign(rhs);
	}

	/// Assignment (shallow copy) by reference.
	public void opAssign(ref Node rhs) @safe nothrow {
		assumeWontThrow(() @trusted{ value_ = rhs.value_; }());
		startMark_ = rhs.startMark_;
		tag_ = rhs.tag_;
		scalarStyle = rhs.scalarStyle;
		collectionStyle = rhs.collectionStyle;
	}

	/** Set element at specified index in a collection.
	 *
	 * This method can only be called on collection nodes.
	 *
	 * If the node is a sequence, index must be integral.
	 *
	 * If the node is a mapping, sets the _value corresponding to the first
	 * key matching index (including conversion, so e.g. "42" matches 42).
	 *
	 * If the node is a mapping and no key matches index, a new key-value
	 * pair is added to the mapping. In sequences the index must be in
	 * range. This ensures behavior siilar to D arrays and associative
	 * arrays.
	 *
	 * To set element at a null index, use YAMLNull for index.
	 *
	 * Params:  value = Value being set
	 *          index = Index of the value to set.
	 *
	 * Throws:  NodeException if the node is not a collection, index is out
	 *          of range or if a non-integral index is used on a sequence node.
	 */
	public void opIndexAssign(K, V)(V value, K index) {
		if (isSequence()) {
			// This ensures K is integral.
			checkSequenceIndex(index);
			static if (isIntegral!K) {
				auto nodes = value_.get!(Node[]);
				static if (is(Unqual!V == Node)) {
					nodes[index] = value;
				} else {
					nodes[index] = Node(value);
				}
				value_ = Value(nodes);
				return;
			}
			assert(false);
		} else if (isMapping()) {
			const idx = findPair(index);
			if (idx < 0) {
				add(index, value);
			} else {
				auto pairs = this.to!(Node.Pair[]);
				static if (is(Unqual!V == Node)) {
					pairs[idx].value = value;
				} else {
					pairs[idx].value = Node(value);
				}
				value_ = Value(pairs);
			}
			return;
		}

		throw new NodeException("Trying to index a " ~ nodeTypeString ~ " node", startMark_);
	}

	/** Foreach over a sequence, getting each element as T.
	 *
	 * If T is Node, simply iterate over the nodes in the sequence.
	 * Otherwise, convert each node to T during iteration.
	 *
	 * Throws:  NodeException if the node is not a sequence or an
	 *          element could not be converted to specified type.
	 */
	public int opApply(T)(int delegate(ref T) dg) {
		enforce(isSequence, new NodeException("Trying to sequence-foreach over a " ~ nodeTypeString ~ " node", startMark_));

		int result = 0;
		foreach (ref node; cast(Node[]) this) {
			static if (is(Unqual!T == Node)) {
				result = dg(node);
			} else {
				T temp = node.to!T;
				result = dg(temp);
			}
			if (result) {
				break;
			}
		}
		return result;
	}

	/** Foreach over a mapping, getting each key/value as K/V.
	 *
	 * If the K and/or V is Node, simply iterate over the nodes in the mapping.
	 * Otherwise, convert each key/value to T during iteration.
	 *
	 * Throws:  NodeException if the node is not a mapping or an
	 *          element could not be converted to specified type.
	 */
	public int opApply(K, V)(int delegate(ref K, ref V) dg) {
		enforce(isMapping, new NodeException("Trying to mapping-foreach over a " ~ nodeTypeString ~ " node", startMark_));

		int result = 0;
		foreach (ref pair; cast(Node.Pair[]) this) {
			static if (is(Unqual!K == Node) && is(Unqual!V == Node)) {
				result = dg(pair.key, pair.value);
			} else static if (is(Unqual!K == Node)) {
				V tempValue = pair.value.to!V;
				result = dg(pair.key, tempValue);
			} else static if (is(Unqual!V == Node)) {
				K tempKey = pair.key.to!K;
				result = dg(tempKey, pair.value);
			} else {
				K tempKey = pair.key.to!K;
				V tempValue = pair.value.to!V;
				result = dg(tempKey, tempValue);
			}

			if (result) {
				break;
			}
		}
		return result;
	}

	/** Add an element to a sequence.
	 *
	 * This method can only be called on sequence nodes.
	 *
	 * If value is a node, it is copied to the sequence directly. Otherwise
	 * value is converted to a node and then stored in the sequence.
	 *
	 * $(P When emitting, all values in the sequence will be emitted. When
	 * using the !!set tag, the user needs to ensure that all elements in
	 * the sequence are unique, otherwise $(B invalid) YAML code will be
	 * emitted.)
	 *
	 * Params:  value = Value to _add to the sequence.
	 */
	public void add(T)(T value) {
		enforce(isSequence(), new NodeException("Trying to add an element to a " ~ nodeTypeString ~ " node", startMark_));

		auto nodes = this.to!(Node[]);
		static if (is(Unqual!T == Node)) {
			nodes ~= value;
		} else {
			nodes ~= Node(value);
		}
		value_ = Value(nodes);
	}

	/** Add a key-value pair to a mapping.
	 *
	 * This method can only be called on mapping nodes.
	 *
	 * If key and/or value is a node, it is copied to the mapping directly.
	 * Otherwise it is converted to a node and then stored in the mapping.
	 *
	 * $(P It is possible for the same key to be present more than once in a
	 * mapping. When emitting, all key-value pairs will be emitted.
	 * This is useful with the "!!pairs" tag, but will result in
	 * $(B invalid) YAML with "!!map" and "!!omap" tags.)
	 *
	 * Params:  key   = Key to _add.
	 *          value = Value to _add.
	 */
	public void add(K, V)(K key, V value) {
		enforce(isMapping(), new NodeException("Trying to add a key-value pair to a " ~ nodeTypeString ~ " node", startMark_));

		auto pairs = this.to!(Node.Pair[]);
		pairs ~= Pair(key, value);
		value_ = Value(pairs);
	}

	/** Determine whether a key is in a mapping, and access its value.
	 *
	 * This method can only be called on mapping nodes.
	 *
	 * Params:   key = Key to search for.
	 *
	 * Returns:  A pointer to the value (as a Node) corresponding to key,
	 *           or null if not found.
	 *
	 * Note:     Any modification to the node can invalidate the returned
	 *           pointer.
	 *
	 * See_Also: contains
	 */
	public auto opBinaryRight(string op, K)(K key) if (op == "in") {
		enforce(isMapping, new NodeException("Trying to use 'in' on a " ~ nodeTypeString ~ " node", startMark_));

		auto idx = findPair(key);
		if (idx < 0) {
			return null;
		} else {
			return &(value_.get!(Node.Pair[])[idx].value);
		}
	}

	/** Remove first (if any) occurence of a value in a collection.
	 *
	 * This method can only be called on collection nodes.
	 *
	 * If the node is a sequence, the first node matching value is removed.
	 * If the node is a mapping, the first key-value pair where _value
	 * matches specified value is removed.
	 *
	 * Params:  rhs = Value to _remove.
	 *
	 * Throws:  NodeException if the node is not a collection.
	 */
	public void remove(T)(T rhs) {
		remove_!(T, No.key, "remove")(rhs);
	}

	/** Remove element at the specified index of a collection.
	 *
	 * This method can only be called on collection nodes.
	 *
	 * If the node is a sequence, index must be integral.
	 *
	 * If the node is a mapping, remove the first key-value pair where
	 * key matches index.
	 *
	 * If the node is a mapping and no key matches index, nothing is removed
	 * and no exception is thrown. This ensures behavior similar to D arrays
	 * and associative arrays.
	 *
	 * Params:  index = Index to remove at.
	 *
	 * Throws:  NodeException if the node is not a collection, index is out
	 *          of range or if a non-integral index is used on a sequence node.
	 */
	public void removeAt(T)(T index) {
		remove_!(T, Yes.key, "removeAt")(index);
	}

	/// Compare with another _node.
	public int opCmp(ref const Node node) const @safe {
		return cmp(node);
	}

	// Compute hash of the node.
	public hash_t toHash() nothrow const {
		const tagHash = tag_.isNull ? 0 : hashOf(tag_.get());
		// Variant toHash is not const at the moment, so we need to const-cast.
		return tagHash + value_.toHash();
	}

	// Construct a node from raw data.
	//
	// Params:  value           = Value of the node.
	//          startMark       = Start position of the node in file.
	//          tag             = Tag of the node.
	//          scalarStyle     = Scalar style of the node.
	//          collectionStyle = Collection style of the node.
	//
	// Returns: Constructed node.
	package static Node rawNode(Value value, const Mark startMark, const Tag tag, const ScalarStyle scalarStyle, const CollectionStyle collectionStyle) {
		Node node;
		node.value_ = value;
		node.startMark_ = startMark;
		node.tag_ = tag;
		node.scalarStyle = scalarStyle;
		node.collectionStyle = collectionStyle;

		return node;
	}

	// Construct Node.Value from user defined type.
	package static Value userValue(T)(T value) nothrow {
		return Value(cast(YAMLObject) new YAMLContainer!T(value));
	}

	// Construct Node.Value from a type it can store directly (after casting if needed)
	package static Value value(T)(T value) @system nothrow if (allowed!T) {
		static if (Value.allowed!T) {
			return Value(value);
		} else static if (isIntegral!T) {
			return Value(cast(long)(value));
		} else static if (isFloatingPoint!T) {
			return Value(cast(real)(value));
		} else static if (isSomeString!T) {
			return Value(to!string(value));
		} else
			static assert(false, "Unknown value type. Is value() in sync with allowed()?");
	}

	// Comparison with another node.
	//
	// Used for ordering in mappings and for opEquals.
	//
	// useTag determines whether or not to consider tags in the comparison.
	package int cmp(const ref Node rhs) const @trusted {
		static int cmp(T1, T2)(T1 a, T2 b) {
			return a > b ? 1 : a < b ? -1 : 0;
		}

		// Compare validity: if both valid, we have to compare further.
		const v1 = isValid;
		const v2 = rhs.isValid;
		if (!v1) {
			return v2 ? -1 : 0;
		}
		if (!v2) {
			return 1;
		}

		const typeCmp = type.opCmp(rhs.type);
		if (typeCmp != 0) {
			return typeCmp;
		}

		static int compareCollections(T)(const ref Node lhs, const ref Node rhs) {
			const c1 = lhs.value_.get!(const T);
			const c2 = rhs.value_.get!(const T);
			if (c1 is c2) {
				return 0;
			}
			if (c1.length != c2.length) {
				return cmp(c1.length, c2.length);
			}
			// Equal lengths, compare items.
			foreach (i; 0 .. c1.length) {
				const itemCmp = c1[i].cmp(c2[i]);
				if (itemCmp != 0) {
					return itemCmp;
				}
			}
			return 0;
		}

		if (isSequence) {
			return compareCollections!(Node[])(this, rhs);
		}
		if (isMapping) {
			return compareCollections!(Pair[])(this, rhs);
		}
		if (isString) {
			return std.algorithm.cmp(value_.get!(const string), rhs.value_.get!(const string));
		}
		if (isInt) {
			return cmp(value_.get!(const long), rhs.value_.get!(const long));
		}
		if (isBool) {
			const b1 = value_.get!(const bool);
			const b2 = rhs.value_.get!(const bool);
			return b1 ? b2 ? 0 : 1 : b2 ? -1 : 0;
		}
		if (isBinary) {
			const b1 = value_.get!(const ubyte[]);
			const b2 = rhs.value_.get!(const ubyte[]);
			return std.algorithm.cmp(b1, b2);
		}
		if (isNull) {
			return 0;
		}
		// Floats need special handling for NaNs .
		// We consider NaN to be lower than any float.
		if (isFloat) {
			const r1 = value_.get!(const real);
			const r2 = rhs.value_.get!(const real);
			if (isNaN(r1)) {
				return isNaN(r2) ? 0 : -1;
			}
			if (isNaN(r2)) {
				return 1;
			}
			// Fuzzy equality.
			if (r1 <= r2 + real.epsilon && r1 >= r2 - real.epsilon) {
				return 0;
			}
			return cmp(r1, r2);
		} else if (isTime) {
			const t1 = value_.get!(const SysTime);
			const t2 = rhs.value_.get!(const SysTime);
			return cmp(t1, t2);
		} else if (isUserType) {
			return value_.get!(const YAMLObject).cmp(rhs.value_.get!(const YAMLObject));
		}
		assert(false, "Unknown type of node for comparison : " ~ type.text);
	}

	// Get a string representation of the node tree. Used for debugging.
	//
	// Params:  level = Level of the node in the tree.
	//
	// Returns: String representing the node tree.
	package string debugString(uint level = 0) {
		string indent;
		foreach (i; 0 .. level) {
			indent ~= " ";
		}

		if (!isValid) {
			return indent ~ "invalid";
		}

		if (isSequence) {
			string result = indent ~ "sequence:\n";
			foreach (ref node; this.to!(Node[])) {
				result ~= node.debugString(level + 1);
			}
			return result;
		}
		if (isMapping) {
			string result = indent ~ "mapping:\n";
			foreach (ref pair; this.to!(Node.Pair[])) {
				result ~= indent ~ " pair\n";
				result ~= pair.key.debugString(level + 2);
				result ~= pair.value.debugString(level + 2);
			}
			return result;
		}
		if (isScalar) {
			return indent ~ "scalar(" ~ (convertsTo!string ? this.to!string : type.text) ~ ")\n";
		}
		assert(false);
	}

	// Get type of the node value (YAMLObject for user types).
	package TypeInfo type() const nothrow @safe {
		alias nothrowType = TypeInfo delegate() const @safe nothrow;
		return (cast(nothrowType)&value_.type)();
	}

	// Determine if the value stored by the node is of specified type.
	//
	// This only works for default YAML types, not for user defined types.
	package bool isType(T)() const @safe nothrow {
		return this.type is typeid(Unqual!T);
	}

	// Is the value a bool?
	private alias isBool = isType!bool;

	// Is the value a raw binary buffer?
	private alias isBinary = isType!(ubyte[]);

	// Is the value an integer?
	private alias isInt = isType!long;

	// Is the value a floating point number?
	private alias isFloat = isType!real;

	// Is the value a string?
	private alias isString = isType!string;

	// Is the value a timestamp?
	private alias isTime = isType!SysTime;

	// Does given node have the same type as this node?
	private bool hasEqualType(const ref Node node) const @safe {
		return this.type is node.type;
	}

	// Return a string describing node type (sequence, mapping or scalar)
	private string nodeTypeString() const @safe nothrow {
		assert(isScalar || isSequence || isMapping, "Unknown node type");
		return isScalar ? "scalar" : isSequence ? "sequence" : isMapping ? "mapping" : "";
	}

	// Determine if the value can be converted to specified type.
	private bool convertsTo(T)() const @safe nothrow {
		if (isType!T) {
			return true;
		}

		// Every type allowed in Value should be convertible to string.
		static if (isSomeString!T) {
			return true;
		} else static if (isFloatingPoint!T) {
			return isInt() || isFloat();
		} else static if (isIntegral!T) {
			return isInt();
		} else {
			return false;
		}
	}

	// Implementation of remove() and removeAt()
	private void remove_(T, Flag!"key" key, string func)(T rhs) {
		enforce(isSequence || isMapping, new NodeException("Trying to " ~ func ~ "() from a " ~ nodeTypeString ~ " node", startMark_));

		static void removeElem(E, I)(ref Node node, I index) {
			auto elems = node.value_.get!(E[]);
			moveAll(elems[cast(size_t) index + 1 .. $], elems[cast(size_t) index .. $ - 1]);
			elems.length--;
			node.value_ = Value(elems);
		}

		if (isSequence()) {
			static long getIndex(ref Node node, ref T rhs) {
				foreach (idx, ref elem; node.to!(Node[])) {
					static if (isSomeString!T) {
						if (elem.convertsTo!T && elem.toString!(T, No.stringConversion) == rhs)
							return idx;
					} else {
						if (elem.convertsTo!T && cast(T) elem == rhs)
							return idx;
					}
				}
				return -1;
			}

			const index = select!key(rhs, getIndex(this, rhs));

			// This throws if the index is not integral.
			checkSequenceIndex(index);

			static if (isIntegral!(typeof(index))) {
				removeElem!Node(this, index);
			} else {
				assert(false, "Non-integral sequence index");
			}
		} else if (isMapping()) {
			const index = findPair!(T, key)(rhs);
			if (index >= 0) {
				removeElem!Pair(this, index);
			}
		}
	}

	// Get index of pair with key (or value, if key is false) matching index.
	private sizediff_t findPair(T, Flag!"key" key = Yes.key)(const ref T index) const {
		const pairs = value_.get!(const Pair[])();
		const(Node)* node;
		foreach (idx, ref const(Pair) pair; pairs) {
			static if (key) {
				node = &pair.key;
			} else {
				node = &pair.value;
			}

			immutable bool typeMatch = (isFloatingPoint!T && (node.isInt || node.isFloat)) || (isIntegral!T && node.isInt) || (isSomeString!T && node.isString) || node.isType!T;
			if (typeMatch && *node == index) {
				return idx;
			}
		}
		return -1;
	}

	// Check if index is integral and in range.
	private void checkSequenceIndex(T)(T index) const {
		assert(isSequence, "checkSequenceIndex() called on a " ~ nodeTypeString ~ " node");

		static if (!isIntegral!T) {
			throw new NodeException("Indexing a sequence with a non-integral type.", startMark_);
		} else {
			enforce(index >= 0 && index < value_.get!(const Node[]).length, new NodeException("Sequence index out of range: " ~ to!string(index), startMark_));
		}
	}

	// Const version of opIndex.
	private ref const(Node) opIndex(T)(T index) const {
		if (isSequence) {
			checkSequenceIndex(index);
			static if (isIntegral!T) {
				return value_.get!(const Node[])[index];
			}
			assert(false);
		} else if (isMapping) {
			auto idx = findPair(index);
			if (idx >= 0) {
				return value_.get!(const Pair[])[idx].value;
			}

			throw new NodeException("Mapping index not found" ~ (isSomeString!T ? ": " ~ to!string(index) : ""), startMark_);
		}
		throw new NodeException("Trying to index a " ~ nodeTypeString ~ " node", startMark_);
	}
}

unittest {
	{
		auto node = Node(42);
		assert(node.isScalar && !node.isSequence && !node.isMapping && !node.isUserType);
		assert(cast(int) node == 42 && cast(float) node == 42.0f && cast(string) node == "42");
		assert(node.to!int == 42 && node.to!float == 42.0f && node.to!string == "42");
		assert(!node.isUserType);
	}
	{
		auto node = Node(new class { int a = 5; });
		assert(node.isUserType);
	}
	{
		auto node = Node("string");
		assert(node.to!string == "string");
	}
}

unittest {
	with (Node([1, 2, 3])) {
		assert(!isScalar() && isSequence && !isMapping && !isUserType);
		assert(length == 3);
		assert(opIndex(2).to!int == 3);
	}

	// Will be emitted as a sequence (default for arrays)
	auto seq = Node([1, 2, 3, 4, 5]);
	// Will be emitted as a set (overriden tag)
	auto set = Node([1, 2, 3, 4, 5], "tag:yaml.org,2002:set");
}

unittest {
	int[string] aa;
	aa["1"] = 1;
	aa["2"] = 2;
	with (Node(aa)) {
		assert(!isScalar() && !isSequence && isMapping && !isUserType);
		assert(length == 2);
		assert(opIndex("2").to!int == 2);
	}

	// Will be emitted as an unordered mapping (default for mappings)
	immutable map = Node([1 : "a", 2 : "b"]);
	assert(map[1] == "a");
	assert(map[2] == "b");
	// Will be emitted as an ordered map (overriden tag)
	immutable omap = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:omap");
	assert(omap[1] == "a");
	assert(omap[2] == "b");
	// Will be emitted as pairs (overriden tag)
	immutable pairs = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:pairs");
	assert(pairs[1] == "a");
	assert(pairs[2] == "b");
}

unittest {
	with (Node(["1", "2"], [1, 2])) {
		assert(!isScalar() && !isSequence && isMapping && !isUserType);
		assert(length == 2);
		assert(opIndex("2").to!int == 2);
	}
	//TODO: implement slicing
	//assert(Node(["1", "2"])[0..$] == ["1", "2"]);

	// Will be emitted as an unordered mapping (default for mappings)
	immutable map = Node([1, 2], ["a", "b"]);
	assert(map[1] == "a");
	assert(map[2] == "b");
	// Will be emitted as an ordered map (overriden tag)
	immutable omap = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:omap");
	assert(omap[1] == "a");
	assert(omap[2] == "b");
	// Will be emitted as pairs (overriden tag)
	immutable pairs = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:pairs");
	assert(pairs[1] == "a");
	assert(pairs[2] == "b");
}

unittest {
	auto node = Node(42);

	assert(node == 42);
	assert(node != "42");
	assert(node != "43");

	auto node2 = Node(YAMLNull());
	assert(node2 == YAMLNull());
	assert(node2.toString() == "null");
}

unittest {
	assertThrown!NodeException(Node("42").to!int);
	Node(YAMLNull()).to!YAMLNull;
}

unittest {
	Node narray = Node([11, 12, 13, 14]);
	Node nmap = Node(["11", "12", "13", "14"], [11, 12, 13, 14]);

	assert(narray[0].to!int == 11);
	assert(null !is collectException(narray[42]));
	assert(nmap["11"].to!int == 11);
	assert(nmap["14"].to!int == 14);
}

unittest {
	Node narray = Node([11, 12, 13, 14]);
	Node nmap = Node(["11", "12", "13", "14"], [11, 12, 13, 14]);

	assert(narray[0].to!int == 11);
	assert(null !is collectException(narray[42]));
	assert(nmap["11"].to!int == 11);
	assert(nmap["14"].to!int == 14);
	assert(null !is collectException(nmap["42"]));

	narray.add(YAMLNull());
	nmap.add(YAMLNull(), "Nothing");
	assert(narray[4].to!YAMLNull == YAMLNull());
	assert(nmap[YAMLNull()].to!string == "Nothing");

	assertThrown!NodeException(nmap[11]);
	assertThrown!NodeException(nmap[14]);
}

// Unittest for opAssign().
unittest {
	auto seq = Node([1, 2, 3, 4, 5]);
	auto assigned = seq;
	assert(seq == assigned, "Node.opAssign() doesn't produce an equivalent copy");
}

// Unittest for contains() and in operator.
unittest {
	auto seq = Node([1, 2, 3, 4, 5]);
	assert(seq.contains(3));
	assert(seq.contains(5));
	assert(!seq.contains("5"));
	assert(!seq.contains(6));
	assert(!seq.contains(float.nan));
	assertThrown(5 !in seq);

	auto seq2 = Node(["1", "2"]);
	assert(seq2.contains("1"));
	assert(!seq2.contains(1));

	auto map = Node(["1", "2", "3", "4"], [1, 2, 3, 4]);
	assert(map.contains(1));
	assert(!map.contains("1"));
	assert(!map.contains(5));
	assert(!map.contains(float.nan));
	assert("1" in map);
	assert("4" in map);
	assert(1 !in map);
	assert("5" !in map);

	assert(!seq.contains(YAMLNull()));
	assert(!map.contains(YAMLNull()));
	assert(YAMLNull() !in map);
	seq.add(YAMLNull());
	map.add("Nothing", YAMLNull());
	assert(seq.contains(YAMLNull()));
	assert(map.contains(YAMLNull()));
	assert(YAMLNull() !in map);
	map.add(YAMLNull(), "Nothing");
	assert(YAMLNull() in map);

	auto map2 = Node([1, 2, 3, 4], [1, 2, 3, 4]);
	assert(!map2.contains("1"));
	assert(map2.contains(1));
	assert("1" !in map2);
	assert(1 in map2);

	// scalar
	assertThrown!NodeException(Node(1).contains(4));
	assertThrown(4 !in Node(1));

	auto mapNan = Node([1.0, 2, double.nan], [1, double.nan, 5]);

	assert(mapNan.contains(double.nan));
	assert(double.nan in mapNan);
}

unittest {
	with (Node([1, 2, 3, 4, 3])) {
		opIndexAssign(42, 3);
		assert(length == 5);
		assert(opIndex(3).to!int == 42);

		opIndexAssign(YAMLNull(), 0);
		assert(opIndex(0) == YAMLNull());
	}
	with (Node(["1", "2", "3"], [4, 5, 6])) {
		opIndexAssign(42, "3");
		opIndexAssign(123, 456);
		assert(length == 4);
		assert(opIndex("3").to!int == 42);
		assert(opIndex(456).to!int == 123);

		opIndexAssign(43, 3);
		//3 and "3" should be different
		assert(length == 5);
		assert(opIndex("3").to!int == 42);
		assert(opIndex(3).to!int == 43);

		opIndexAssign(YAMLNull(), "2");
		assert(opIndex("2") == YAMLNull());
	}
}

unittest {
	Node n1 = Node(Node.Value(11L));
	Node n2 = Node(Node.Value(12L));
	Node n3 = Node(Node.Value(13L));
	Node n4 = Node(Node.Value(14L));
	Node narray = Node([n1, n2, n3, n4]);

	int[] array, array2;
	foreach (int value; narray) {
		array ~= value;
	}

	foreach (Node node; narray) {
		array2 ~= node.to!int;
	}

	assert(array == [11, 12, 13, 14]);
	assert(array2 == [11, 12, 13, 14]);
}

unittest {
	Node n1 = Node(11L);
	Node n2 = Node(12L);
	Node n3 = Node(13L);
	Node n4 = Node(14L);

	Node k1 = Node("11");
	Node k2 = Node("12");
	Node k3 = Node("13");
	Node k4 = Node("14");

	Node nmap1 = Node([Pair(k1, n1), Pair(k2, n2), Pair(k3, n3), Pair(k4, n4)]);

	int[string] expected = ["11" : 11, "12" : 12, "13" : 13, "14" : 14];
	int[string] array;
	foreach (string key, int value; nmap1) {
		array[key] = value;
	}

	assert(array == expected);

	Node nmap2 = Node([Pair(k1, Node(5L)), Pair(k2, Node(true)), Pair(k3, Node(1.0L)), Pair(k4, Node("yarly"))]);

	foreach (string key, Node value; nmap2) {
		switch (key) {
			case "11":
				assert(cast(int) value == 5);
				break;
			case "12":
				assert(cast(bool) value == true);
				break;
			case "13":
				assert(cast(float) value == 1.0);
				break;
			case "14":
				assert(cast(string) value == "yarly");
				break;
			default:
				assert(false);
		}
	}
}

unittest {
	with (Node([1, 2, 3, 4])) {
		add(5.0f);
		assert(cast(float) opIndex(4) == 5.0f);
	}
}

unittest {
	with (Node([1, 2], [3, 4])) {
		add(5, "6");
		assert(cast(string) opIndex(5) == "6");
	}
}

unittest {
	auto mapping = Node(["foo", "baz"], ["bar", "qux"]);
	assert("bad" !in mapping && ("bad" in mapping) is null);
	Node* foo = "foo" in mapping;
	assert(foo !is null);
	assert(*foo == Node("bar"));
	assert((*foo).toString() == "bar");
	assert(cast(string)*foo == "bar");
	*foo = Node("newfoo");
	assert(mapping["foo"] == Node("newfoo"));
}

unittest {
	with (Node([1, 2, 3, 4, 3])) {
		remove(3);
		assert(length == 4);
		assert(opIndex(2).to!int == 4);
		assert(opIndex(3).to!int == 3);

		add(YAMLNull());
		assert(length == 5);
		remove(YAMLNull());
		assert(length == 4);
	}
	with (Node(["1", "2", "3"], [4, 5, 6])) {
		remove(4);
		assert(length == 2);
		add("nullkey", YAMLNull());
		assert(length == 3);
		remove(YAMLNull());
		assert(length == 2);
	}
}

unittest {
	with (Node([1, 2, 3, 4, 3])) {
		removeAt(3);
		assertThrown!NodeException(removeAt("3"));
		assert(length == 4);
		assert(opIndex(3).to!int == 3);
	}
	with (Node(["1", "2", "3"], [4, 5, 6])) {
		// no integer 2 key, so don't remove anything
		removeAt(2);
		assert(length == 3);
		removeAt("2");
		assert(length == 2);
		add(YAMLNull(), "nullval");
		assert(length == 3);
		removeAt(YAMLNull());
		assert(length == 2);
	}
}

// Merge a pair into an array of pairs based on merge rules in the YAML spec.
//
// The new pair will only be added if there is not already a pair
// with the same key.
//
// Params:  pairs   = Appender managing the array of pairs to merge into.
//          toMerge = Pair to merge.
package void merge(ref Appender!(Node.Pair[]) pairs, ref Node.Pair toMerge) {
	foreach (ref pair; pairs.data) {
		if (pair.key == toMerge.key) {
			return;
		}
	}
	pairs.put(toMerge);
}

// Merge pairs into an array of pairs based on merge rules in the YAML spec.
//
// Any new pair will only be added if there is not already a pair
// with the same key.
//
// Params:  pairs   = Appender managing the array of pairs to merge into.
//          toMerge = Pairs to merge.
package void merge(ref Appender!(Node.Pair[]) pairs, Node.Pair[] toMerge) {
	bool eq(ref Node.Pair a, ref Node.Pair b) {
		return a.key == b.key;
	}

	foreach (ref pair; toMerge) {
		if (!canFind!eq(pairs.data, pair)) {
			pairs.put(pair);
		}
	}
}

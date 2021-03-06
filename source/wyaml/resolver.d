//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * Implements a class that resolves YAML tags. This can be used to implicitly
 * resolve tags for custom data types, removing the need to explicitly
 * specify tags in YAML. A tutorial can be found
 * $(LINK2 ../tutorials/custom_types.html, here).
 *
 * Code based on $(LINK2 http://www.pyyaml.org, PyYAML).
 */
module wyaml.resolver;

import std.exception;
import std.regex;
import std.typecons;
import std.utf;

import wyaml.exception;
import wyaml.node;
import wyaml.tag;

/**
 * Resolves YAML tags (data types).
 *
 * Can be used to implicitly resolve custom data types of scalar values.
 */
final class Resolver {
	// Default tag to use for scalars.
	private static immutable Tag defaultScalarTag_ = Tag("tag:yaml.org,2002:str");
	// Default tag to use for sequences.
	private static immutable Tag defaultSequenceTag_ = Tag("tag:yaml.org,2002:seq");
	// Default tag to use for mappings.
	private static immutable Tag defaultMappingTag_ = Tag("tag:yaml.org,2002:map");

	/*
		 * Arrays of scalar resolver tuples indexed by starting character of a scalar.
		 *
		 * Each tuple stores regular expression the scalar must match,
		 * and tag to assign to it if it matches.
		 */
	Tuple!(Tag, Regex!char)[][dchar] yamlImplicitResolvers_;

	@disable bool opEquals(ref Resolver);
	@disable int opCmp(ref Resolver);

	/**
		 * Construct a Resolver.
		 *
		 * If you don't want to implicitly resolve default YAML tags/data types,
		 * you can use defaultImplicitResolvers to disable default resolvers.
		 *
		 * Params:  defaultImplicitResolvers = Use default YAML implicit resolvers?
		 */
	public this(Flag!"useDefaultImplicitResolvers" defaultImplicitResolvers = Yes.useDefaultImplicitResolvers) @safe pure nothrow {
		if (defaultImplicitResolvers) {
			addImplicitResolvers();
		}
	}

	/**
		 * Add an implicit scalar resolver.
		 *
		 * If a scalar matches regexp and starts with any character in first,
		 * its _tag is set to tag. If it matches more than one resolver _regexp
		 * resolvers added _first override ones added later. Default resolvers
		 * override any user specified resolvers, but they can be disabled in
		 * Resolver constructor.
		 *
		 * If a scalar is not resolved to anything, it is assigned the default
		 * YAML _tag for strings.
		 *
		 * Params:  tag    = Tag to resolve to.
		 *          regexp = Regular expression the scalar must match to have this _tag.
		 *          first  = String of possible starting characters of the scalar.
		 *
		 * Examples:
		 *
		 * Resolve scalars starting with 'A' to !_tag :
		 * --------------------
		 * import std.regex;
		 *
		 * import wyaml.all;
		 *
		 * void main()
		 * {
		 *     auto loader = Loader("file.txt");
		 *     auto resolver = new Resolver();
		 *     resolver.addImplicitResolver("!tag", ctRegex!("A.*"), "A");
		 *     loader.resolver = resolver;
		 *
		 *     //Note that we have no constructor from tag "!tag", so we can't
		 *     //actually load anything that resolves to this tag.
		 *     //See Constructor API documentation and tutorial for more information.
		 *
		 *     auto node = loader.load();
		 * }
		 * --------------------
		 */
	public void addImplicitResolver(string tag, Regex!char regexp, dstring first) pure @safe nothrow {
		foreach (const dchar c; first) {
			if ((c in yamlImplicitResolvers_) is null) {
				yamlImplicitResolvers_[c] = [];
			}
			yamlImplicitResolvers_[c] ~= tuple(Tag(tag), regexp);
		}
	}

	/*
		 * Resolve tag of a node.
		 *
		 * Params:  kind     = Type of the node.
		 *          tag      = Explicit tag of the node, if any.
		 *          value    = Value of the node, if any.
		 *          implicit = Should the node be implicitly resolved?
		 *
		 * If the tag is already specified and not non-specific, that tag will
		 * be returned.
		 *
		 * Returns: Resolved tag.
		 */
	package Tag resolve(const NodeID kind, const Tag tag, const string value, const bool implicit) @safe {
		if (!tag.isNull() && tag.get() != "!") {
			return tag;
		}

		final switch (kind) {
			case NodeID.Scalar:
				if (!implicit) {
					return defaultScalarTag_;
				}

				//Get the first char of the value.
				size_t dummy;
				const dchar first = value.length == 0 ? '\0' : decode(value, dummy);

				auto resolvers = (first in yamlImplicitResolvers_) is null ? [] : yamlImplicitResolvers_[first];

				//If regexp matches, return tag.
				foreach (resolver; resolvers)
					if (!(match(value, resolver[1]).empty)) {
						return resolver[0];
					}
				return defaultScalarTag_;
			case NodeID.Sequence:
				return defaultSequenceTag_;
			case NodeID.Mapping:
				return defaultMappingTag_;
		}
	}

	///Return default scalar tag.
	package Tag defaultScalarTag() const pure @safe nothrow {
		return defaultScalarTag_;
	}

	///Return default sequence tag.
	package Tag defaultSequenceTag() const pure @safe nothrow {
		return defaultSequenceTag_;
	}

	///Return default mapping tag.
	package Tag defaultMappingTag() const pure @safe nothrow {
		return defaultMappingTag_;
	}

	// Add default implicit resolvers.
	private void addImplicitResolvers() @safe pure nothrow {
		enum boolRegex = `^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$`;
		enum floatRegex = `^(?:[-+]?([0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|[-+]?(?:[0-9][0-9_]*)?\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$`;
		enum intRegex = `^(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$`;
		enum mergeRegex = `^<<$`;
		enum nullRegex = `^$|^(?:~|null|Null|NULL)$`;
		enum timestampRegex = `^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?[Tt]|[ \t]+[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\\.[0-9]*)?(?:[ \t]*Z|[-+][0-9][0-9]?(?::[0-9][0-9])?)?$`;
		enum valueRegex = `^=$`;
		enum illegalRegex = `^(?:!|&|\*)$`;
		version (unittest) { //Combination of unit tests + ctRegex currently causes compiler to run out of memory
			enum compiledBoolRegex = regex(boolRegex);
			enum compiledFloatRegex = regex(floatRegex);
			enum compiledIntRegex = regex(intRegex);
			enum compiledMergeRegex = regex(mergeRegex);
			enum compiledNullRegex = regex(nullRegex);
			enum compiledTimestampRegex = regex(timestampRegex);
			enum compiledValueRegex = regex(valueRegex);
			enum compiledIllegalRegex = regex(illegalRegex);
		} else {
			enum compiledBoolRegex = ctRegex!boolRegex;
			enum compiledFloatRegex = ctRegex!floatRegex;
			enum compiledIntRegex = ctRegex!intRegex;
			enum compiledMergeRegex = ctRegex!mergeRegex;
			enum compiledNullRegex = ctRegex!nullRegex;
			enum compiledTimestampRegex = ctRegex!timestampRegex;
			enum compiledValueRegex = ctRegex!valueRegex;
			enum compiledIllegalRegex = ctRegex!illegalRegex;
		}
		addImplicitResolver("tag:yaml.org,2002:bool", compiledBoolRegex, "yYnNtTfFoO");
		addImplicitResolver("tag:yaml.org,2002:float", compiledFloatRegex, "-+0123456789.");
		addImplicitResolver("tag:yaml.org,2002:int", compiledIntRegex, "-+0123456789");
		addImplicitResolver("tag:yaml.org,2002:merge", compiledMergeRegex, "<");
		addImplicitResolver("tag:yaml.org,2002:null", compiledNullRegex, "~nN\0");
		addImplicitResolver("tag:yaml.org,2002:timestamp", compiledTimestampRegex, "0123456789");
		addImplicitResolver("tag:yaml.org,2002:value", compiledValueRegex, "=");

		//The following resolver is only for documentation purposes. It cannot work
		//because plain scalars cannot start with '!', '&', or '*'.
		addImplicitResolver("tag:yaml.org,2002:yaml", compiledIllegalRegex, "!&*");
	}
}

@safe unittest {
	auto resolver = new Resolver();

	bool tagMatch(string tag, string[] values) {
		immutable expected = Tag(tag);
		foreach (value; values) {
			immutable resolved = resolver.resolve(NodeID.Scalar, Tag(), value, true);
			if (expected != resolved) {
				return false;
			}
		}
		return true;
	}

	assert(tagMatch("tag:yaml.org,2002:bool", ["yes", "NO", "True", "on"]));
	assert(tagMatch("tag:yaml.org,2002:float", ["6.8523015e+5", "685.230_15e+03", "685_230.15", "190:20:30.15", "-.inf", ".NaN"]));
	assert(tagMatch("tag:yaml.org,2002:int", ["685230", "+685_230", "02472256", "0x_0A_74_AE", "0b1010_0111_0100_1010_1110", "190:20:30"]));
	assert(tagMatch("tag:yaml.org,2002:merge", ["<<"]));
	assert(tagMatch("tag:yaml.org,2002:null", ["~", "null", ""]));
	assert(tagMatch("tag:yaml.org,2002:str", ["abcd", "9a8b", "9.1adsf"]));
	assert(tagMatch("tag:yaml.org,2002:timestamp", ["2001-12-15T02:59:43.1Z", "2001-12-14t21:59:43.10-05:00", "2001-12-14 21:59:43.10 -5", "2001-12-15 2:59:43.10", "2002-12-14"]));
	assert(tagMatch("tag:yaml.org,2002:value", ["="]));
	assert(tagMatch("tag:yaml.org,2002:yaml", ["!", "&", "*"]));
}

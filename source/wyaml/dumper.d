//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
* YAML dumper.
*
* Code based on $(LINK2 http://www.pyyaml.org, PyYAML).
*/
module wyaml.dumper;

import std.range;
import std.typecons;

import wyaml.anchor;
import wyaml.emitter;
import wyaml.event;
import wyaml.exception;
import wyaml.linebreak;
import wyaml.node;
import wyaml.representer;
import wyaml.resolver;
import wyaml.serializer;
import wyaml.tagdirective;

/**
* Dumps YAML documents to files or streams.
*
* User specified Representer and/or Resolver can be used to support new
* tags / data types.
*
* Setters are provided to affect output details (style, encoding, etc.).
*/
public struct Dumper {
	//Resolver to resolve tags.
	private Resolver resolver_;
	//Representer to represent data types.
	private Representer representer_;

	//Write scalars in canonical form?
	private bool canonical_;
	//Indentation width.
	private int indent_ = 2;
	//Preferred text width.
	private uint textWidth_ = 80;
	//Line break to use.
	private LineBreak lineBreak_ = LineBreak.Unix;
	//YAML version string.
	private string yamlVersion_ = "1.1";
	//Tag directives to use.
	private TagDirective[] tags_ = null;
	//Always write document start?
	private Flag!"explicitStart" explicitStart_ = No.explicitStart;
	//Always write document end?
	private Flag!"explicitEnd" explicitEnd_ = No.explicitEnd;

	//Name of the output file or stream, used in error messages.
	private string name_ = "<unknown>";

	///Set stream _name. Used in debugging messages.
	public void name(string name) {
		name_ = name;
	}

	///Specify custom Resolver to use.
	public void resolver(Resolver resolver) {
		resolver_ = resolver;
	}

	///Specify custom Representer to use.
	public void representer(Representer representer) {
		representer_ = representer;
	}

	///Write scalars in _canonical form?
	public void canonical(bool canonical) {
		canonical_ = canonical;
	}

	///Set indentation width. 2 by default. Must not be zero.
	public void indent(uint indent) in {
		assert(indent != 0, "Can't use zero YAML indent width");
	}
	body {
		indent_ = indent;
	}

	///Set preferred text _width.
	public void textWidth(uint width) {
		textWidth_ = width;
	}

	///Set line break to use. Unix by default.
	public void lineBreak(LineBreak lineBreak) {
		lineBreak_ = lineBreak;
	}

	///Always explicitly write document start?
	public void explicitStart(bool explicit) {
		explicitStart_ = explicit ? Yes.explicitStart : No.explicitStart;
	}

	///Always explicitly write document end?
	public void explicitEnd(bool explicit) {
		explicitEnd_ = explicit ? Yes.explicitEnd : No.explicitEnd;
	}

	///Specify YAML version string. "1.1" by default.
	public void yamlVersion(string ver) {
		yamlVersion_ = ver;
	}

	/**
	* Specify tag directives.
	*
	* A tag directive specifies a shorthand notation for specifying _tags.
	* Each tag directive associates a handle with a prefix. This allows for
	* compact tag notation.
	*
	* Each handle specified MUST start and end with a '!' character
	* (a single character "!" handle is allowed as well).
	*
	* Only alphanumeric characters, '-', and '__' may be used in handles.
	*
	* Each prefix MUST not be empty.
	*
	* The "!!" handle is used for default YAML _tags with prefix
	* "tag:yaml.org,2002:". This can be overridden.
	*
	* Params:  tags = Tag directives (keys are handles, values are prefixes).
	*/
	public void tagDirectives(TagDirective[] directives) nothrow {
		tags_ = directives;
	}

	/**
	* Dump one or more YAML _documents to the file/stream.
	*
	* Note that while you can call dump() multiple times on the same
	* dumper, you will end up writing multiple YAML "files" to the same
	* file/stream.
	*
	* Params:  documents = Documents to _dump (root nodes of the _documents).
	*
	* Throws:  YAMLException on error (e.g. invalid nodes,
	*          unable to write to file/stream).
	*/
	public void dump(T)(T stream, Node[] documents...) if (isOutputRange!(T, char[])) {
		if (resolver_ is null) {
			resolver_ = new Resolver;
		}
		if (representer_ is null) {
			representer_ = new Representer;
		}
		try {
			auto emitter = Emitter!T(stream, canonical_, indent_, textWidth_, lineBreak_);
			auto serializer = Serializer!T(emitter, resolver_, explicitStart_, explicitEnd_, yamlVersion_, tags_);
			foreach (ref document; documents) {
				representer_.represent(serializer, document);
			}
		}
		catch (YAMLException e) {
			throw new YAMLException("Unable to dump YAML to stream " ~ name_ ~ " : " ~ e.msg);
		}
	}

	/*
	* Emit specified events. Used for debugging/testing.
	*
	* Params:  events = Events to emit.
	*
	* Throws:  YAMLException if unable to emit.
	*/
	version(unittest) package void emit(T)(T stream, Event[] events) if (isOutputRange!(T, char[])) {
		try {
			auto emitter = Emitter!T(stream, canonical_, indent_, textWidth_, lineBreak_);
			foreach (ref event; events) {
				emitter.emit(event);
			}
		}
		catch (YAMLException e) {
			throw new YAMLException("Unable to emit YAML to stream " ~ name_ ~ " : " ~ e.msg);
		}
	}
}
///Write to a file
unittest {
	auto node = Node([1, 2, 3, 4, 5]);
	scope(exit) if ("file.yaml".exists) std.file.remove("file.yaml");
	Dumper().dump(File("file.yaml", "w").lockingTextWriter, node);
}
///Write multiple YAML documents to a file
unittest {
	auto node1 = Node([1, 2, 3, 4, 5]);
	auto node2 = Node("This document contains only one string");
	scope(exit) if ("file.yaml".exists) std.file.remove("file.yaml");
	Dumper().dump(File("file.yaml", "w").lockingTextWriter, node1, node2);
}
///Write to memory
unittest {
	auto stream = new OutBuffer;
	auto node = Node([1, 2, 3, 4, 5]);
	Dumper().dump(stream, node);
}
///Use a custom representer/resolver to support custom data types and/or implicit tags
unittest {
	auto node = Node([1, 2, 3, 4, 5]);
	auto representer = new Representer;
	auto resolver = new Resolver;
	//Add representer functions / resolver expressions here...
	auto dumper = Dumper();
	dumper.representer = representer;
	dumper.resolver = resolver;
	scope(exit) if ("file.yaml".exists) std.file.remove("file.yaml");
	dumper.dump(File("file.yaml", "w").lockingTextWriter, node);
}
unittest {
	auto dumper = Dumper();
	TagDirective[] directives;
	directives ~= TagDirective("!short!", "tag:long.org,2011:");
	//This will emit tags starting with "tag:long.org,2011"
	//with a "!short!" prefix instead.
	dumper.tagDirectives(directives);
	scope(exit) if ("file.yaml".exists) std.file.remove("file.yaml");
	dumper.dump(File("file.yaml", "w").lockingTextWriter, Node("foo"));
}
version (unittest) import std.outbuffer, std.stdio, std.file;
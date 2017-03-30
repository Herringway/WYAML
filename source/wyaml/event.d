//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * YAML events.
 * Code based on PyYAML: http://www.pyyaml.org
 */
module wyaml.event;

import std.algorithm;
import std.array;
import std.conv;
import std.typecons;

import wyaml.anchor;
import wyaml.exception;
import wyaml.reader;
import wyaml.style;
import wyaml.tag;
import wyaml.tagdirective;

///Event types.
package enum EventID : ubyte {
	Invalid = 0, /// Invalid (uninitialized) event.
	StreamStart, /// Stream start
	StreamEnd, /// Stream end
	DocumentStart, /// Document start
	DocumentEnd, /// Document end
	Alias, /// Alias
	Scalar, /// Scalar
	SequenceStart, /// Sequence start
	SequenceEnd, /// Sequence end
	MappingStart, /// Mapping start
	MappingEnd /// Mapping end
}

package struct Event {
	@disable int opCmp(ref Event) const;
	@disable bool opEquals(ref Event) const;
	@disable size_t toHash() nothrow @safe;

	///Value of the event, if any.
	string value;
	///Start position of the event in file/stream.
	Mark startMark;
	///End position of the event in file/stream.
	Mark endMark;
	union {
		struct {
			///Anchor of the event, if any.
			private Anchor anchor_;
			///Tag of the event, if any.
			private Tag tag_;
		}
		///Tag directives, if this is a DocumentStart.
		private TagDirective[] tagDirectives_;
	}
	///Event type.
	EventID id = EventID.Invalid;
	///Style of scalar event, if this is a scalar event.
	ScalarStyle scalarStyle = ScalarStyle.Invalid;
	///Should the tag be implicitly resolved?
	bool implicit;
	/**
	 * Is this document event explicit?
	 *
	 * Used if this is a DocumentStart or DocumentEnd.
	 */
	alias explicitDocument = implicit;
	///TODO figure this out - Unknown, used by PyYAML with Scalar events.
	bool implicit_2;
	///Collection style, if this is a SequenceStart or MappingStart.
	CollectionStyle collectionStyle = CollectionStyle.Invalid;

	///Is this a null (uninitialized) event?
	bool isNull() const pure @safe nothrow @nogc {
		return id == EventID.Invalid;
	}

	///Get string representation of the token ID.
	string idString() const @safe {
		return to!string(id);
	}
	auto tag() const {
		return tag_;
	}
	auto anchor() const {
		return anchor_;
	}
	auto tagDirectives() const {
		assert(id == EventID.DocumentStart, "Cannot retrieve tag directives for non-document start events");
		return tagDirectives_;
	}
	//Uninitialized Events are invalid. Disabling default constructors allows us to avoid that.
	@disable this();

	this(EventID id, Mark start, Mark end, Anchor anchor, Tag tag) @trusted pure nothrow @nogc {
		this(id, start, end, anchor);
		tag_ = tag;
	}
	this(EventID id, Mark start, Mark end, Anchor anchor) @trusted pure nothrow @nogc {
		this(id, start, end);
		anchor_ = anchor;
	}
	this(Mark start, Mark end, TagDirective[] directives) @safe pure nothrow @nogc {
		this(directives);
		startMark = start;
		endMark = end;
	}
	this(TagDirective[] directives) @trusted pure nothrow @nogc {
		this(EventID.DocumentStart);
		tagDirectives_ = directives;
	}
	this(EventID id, Mark start, Mark end) @safe pure nothrow @nogc {
		this(id);
		startMark = start;
		endMark = end;
	}
	this(EventID id) @safe pure nothrow @nogc {
		this.id = id;
	}
	this(EventID id, Anchor anchor) @trusted pure nothrow @nogc {
		assert(id != EventID.DocumentStart);
		this(id);
		anchor_ = anchor;
	}
}

/**
 * Construct a collection (mapping or sequence) start event.
 *
 * Params:  start    = Start position of the event in the file/stream.
 *          end      = End position of the event in the file/stream.
 *          anchor   = Anchor of the sequence, if any.
 *          tag      = Tag of the sequence, if specified.
 *          implicit = Should the tag be implicitly resolved?
 *          style    = Whether to use block style or flow style
 */
package Event collectionStartEvent(EventID id, const Mark start, const Mark end, const Anchor anchor, const Tag tag, const bool implicit, const CollectionStyle style) @safe @nogc pure nothrow
in {
	assert(id.among(EventID.SequenceStart, EventID.MappingStart));
}
body {
	auto event = Event(id, start, end, anchor, tag);
	event.implicit = implicit;
	event.collectionStyle = style;
	return event;
}

/**
 * Construct a document start event.
 *
 * Params:  start         = Start position of the event in the file/stream.
 *          end           = End position of the event in the file/stream.
 *          explicit      = Is this an explicit document start?
 *          YAMLVersion   = YAML version string of the document.
 *          tagDirectives = Tag directives of the document.
 */
package Event documentStartEvent(const Mark start, const Mark end, const bool explicit, string YAMLVersion, TagDirective[] tagDirectives) @safe @nogc pure nothrow {
	Event result = Event(start, end, tagDirectives);
	result.value = YAMLVersion;
	result.explicitDocument = explicit;
	return result;
}
/**
 * Construct a document start event.
 *
 * Params:
 *          explicit      = Is this an explicit document start?
 *          YAMLVersion   = YAML version string of the document.
 *          tagDirectives = Tag directives of the document.
 */
package Event documentStartEvent(const bool explicit, string YAMLVersion, TagDirective[] tagDirectives) @safe @nogc pure nothrow {
	Event result = Event(tagDirectives);
	result.value = YAMLVersion;
	result.explicitDocument = explicit;
	return result;
}
/**
 * Construct a document end event.
 *
 * Params:
 *   explicit = Is this an explicit document end?
 */
package Event documentEndEvent(const bool explicit) pure @safe nothrow {
	Event result = Event(EventID.DocumentEnd);
	result.explicitDocument = explicit;
	return result;
}
/**
 * Construct a document end event.
 *
 * Params:  start    = Start position of the event in the file/stream.
 *          end      = End position of the event in the file/stream.
 *          explicit = Is this an explicit document end?
 */
package Event documentEndEvent(const Mark start, const Mark end, const bool explicit) @safe @nogc pure nothrow {
	Event result = Event(EventID.DocumentEnd, start, end);
	result.explicitDocument = explicit;
	return result;
}
/// Construct a scalar event.
///
/// Params:  start    = Start position of the event in the file/stream.
///          end      = End position of the event in the file/stream.
///          anchor   = Anchor of the scalar, if any.
///          tag      = Tag of the scalar, if specified.
///          implicit = Should the tag be implicitly resolved?
///          value    = String value of the scalar.
///          style    = Scalar style.
package Event scalarEvent(const Mark start, const Mark end, const Anchor anchor, const Tag tag, const Tuple!(bool, bool) implicit, const string value, const ScalarStyle style = ScalarStyle.Invalid) @safe @nogc pure nothrow {
	Event result = Event(EventID.Scalar, start, end, anchor, tag);
	result.value = value;
	result.scalarStyle = style;
	result.implicit = implicit[0];
	result.implicit_2 = implicit[1];
	return result;
}
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
import wyaml.tag;
import wyaml.tagdirective;
import wyaml.style;


package:
///Event types.
enum EventID : ubyte {
    Invalid = 0,     /// Invalid (uninitialized) event.
    StreamStart,     /// Stream start
    StreamEnd,       /// Stream end
    DocumentStart,   /// Document start
    DocumentEnd,     /// Document end
    Alias,           /// Alias
    Scalar,          /// Scalar
    SequenceStart,   /// Sequence start
    SequenceEnd,     /// Sequence end
    MappingStart,    /// Mapping start
    MappingEnd       /// Mapping end
}
struct Event {
    @disable int opCmp(ref Event);

    ///Value of the event, if any.
    string value;
    ///Start position of the event in file/stream.
    Mark startMark;
    ///End position of the event in file/stream.
    Mark endMark;
    union {
        struct {
            ///Anchor of the event, if any.
            Anchor anchor;
            ///Tag of the event, if any.
            Tag tag;
        }
        ///Tag directives, if this is a DocumentStart.
        //TagDirectives tagDirectives;
        TagDirective[] tagDirectives;
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
    @property bool isNull() const pure @safe nothrow {return id == EventID.Invalid;}

    ///Get string representation of the token ID.
    @property string idString() const @safe {return to!string(id);}
}

/**
 * Construct a simple event.
 *
 * Params:  start    = Start position of the event in the file/stream.
 *          end      = End position of the event in the file/stream.
 *          anchor   = Anchor, if this is an alias event.
 */
Event event(EventID id)(const Mark start, const Mark end, const Anchor anchor = Anchor()) {
    Event result;
    result.startMark = start;
    result.endMark   = end;
    result.anchor    = anchor;
    result.id        = id;
    return result;
}

pure @safe nothrow unittest {
    auto v = event!(EventID.SequenceStart)(Mark(), Mark(), Anchor());
}
/**
 * Construct a collection (mapping or sequence) start event.
 *
 * Params:  start    = Start position of the event in the file/stream.
 *          end      = End position of the event in the file/stream.
 *          anchor   = Anchor of the sequence, if any.
 *          tag      = Tag of the sequence, if specified.
 *          implicit = Should the tag be implicitly resolved?
 */
Event collectionStartEvent(EventID id)
    (const Mark start, const Mark end, const Anchor anchor, const Tag tag,
     const bool implicit, const CollectionStyle style) in {
        static assert(id.among(EventID.SequenceStart, EventID.SequenceEnd,
                      EventID.MappingStart, EventID.MappingEnd));
} body {
    Event result = event!id(start, end, anchor);
    result.tag             = tag;
    result.implicit        = implicit;
    result.collectionStyle = style;
    return result;
}
pure @safe nothrow unittest {
    auto v = collectionStartEvent!(EventID.SequenceStart)(Mark(), Mark(), Anchor(), Tag(), false, CollectionStyle.Invalid);
}

///Aliases for simple events.
alias streamEndEvent = event!(EventID.StreamEnd);
alias aliasEvent = event!(EventID.Alias);
alias sequenceEndEvent = event!(EventID.SequenceEnd);
alias mappingEndEvent = event!(EventID.MappingEnd);
alias streamStartEvent = event!(EventID.StreamStart);

///Aliases for collection start events.
alias collectionStartEvent!(EventID.SequenceStart) sequenceStartEvent;
alias collectionStartEvent!(EventID.MappingStart)  mappingStartEvent;

/**
 * Construct a document start event.
 *
 * Params:  start         = Start position of the event in the file/stream.
 *          end           = End position of the event in the file/stream.
 *          explicit      = Is this an explicit document start?
 *          YAMLVersion   = YAML version string of the document.
 *          tagDirectives = Tag directives of the document.
 */
Event documentStartEvent(const Mark start, const Mark end, const bool explicit, string YAMLVersion,
                         TagDirective[] tagDirectives) pure nothrow {
    Event result = event!(EventID.DocumentStart)(start, end);
    result.value            = YAMLVersion;
    result.explicitDocument = explicit;
    result.tagDirectives    = tagDirectives;
    return result;
}

pure nothrow unittest {
    auto v = documentStartEvent(Mark(), Mark(), false, "", []);
}
/**
 * Construct a document end event.
 *
 * Params:  start    = Start position of the event in the file/stream.
 *          end      = End position of the event in the file/stream.
 *          explicit = Is this an explicit document end?
 */
Event documentEndEvent(const Mark start, const Mark end, const bool explicit) pure @safe nothrow {
    Event result = event!(EventID.DocumentEnd)(start, end);
    result.explicitDocument = explicit;
    return result;
}

pure @safe nothrow unittest {
    auto v = documentEndEvent(Mark(), Mark(), false);
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
Event scalarEvent(const Mark start, const Mark end, const Anchor anchor, const Tag tag,
                  const Tuple!(bool, bool) implicit, const string value,
                  const ScalarStyle style = ScalarStyle.Invalid) @safe pure nothrow @nogc {
    Event result = event!(EventID.Scalar)(start, end, anchor);
    result.value       = value;
    result.tag         = tag;
    result.scalarStyle = style;
    result.implicit    = implicit[0];
    result.implicit_2  = implicit[1];
    return result;
}

pure @safe nothrow unittest {
    auto v = scalarEvent(Mark(), Mark(), Anchor(), Tag(), tuple(false, false), "");
}
//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// YAML tokens.
/// Code based on PyYAML: http://www.pyyaml.org
module wyaml.token;

import std.conv;

import wyaml.exception;
import wyaml.reader;
import wyaml.style;

/// Token types.
package enum TokenID : ubyte {
	/// Invalid (uninitialized) token
	Invalid = 0,
	/// DIRECTIVE
	Directive,
	/// DOCUMENT-START
	DocumentStart,
	/// DOCUMENT-END
	DocumentEnd,
	/// STREAM-START
	StreamStart,
	/// STREAM-END
	StreamEnd,
	/// BLOCK-SEQUENCE-START
	BlockSequenceStart,
	/// BLOCK-MAPPING-START
	BlockMappingStart,
	/// BLOCK-END
	BlockEnd,
	/// FLOW-SEQUENCE-START
	FlowSequenceStart,
	/// FLOW-MAPPING-START
	FlowMappingStart,
	/// FLOW-SEQUENCE-END
	FlowSequenceEnd,
	/// FLOW-MAPPING-END
	FlowMappingEnd,
	/// KEY
	Key,
	/// VALUE
	Value,
	/// BLOCK-ENTRY
	BlockEntry,
	/// FLOW-ENTRY
	FlowEntry,
	/// ALIAS
	Alias,
	/// ANCHOR
	Anchor,
	/// TAG
	Tag,
	/// SCALAR
	Scalar
}

/// Specifies the type of a tag directive token.
package enum DirectiveType : ubyte {
	// YAML version directive.
	YAML,
	// Tag directive.
	TAG,
	// Any other directive is "reserved" for future YAML versions.
	Reserved
}

/// Token produced by scanner.
///
package struct Token {
	@disable int opCmp(ref Token) const;
	@disable bool opEquals(ref Token) const;
	@disable size_t toHash() nothrow @safe;

	/// Value of the token, if any.
	///
	/// Values are char[] instead of string, as Parser may still change them in a few
	/// cases. Parser casts values to strings when producing Events.
	string value;
	/// Start position of the token in file/stream.
	Mark startMark;
	/// End position of the token in file/stream.
	Mark endMark;
	/// Token type.
	TokenID id;
	/// Style of scalar token, if this is a scalar token.
	ScalarStyle style;
	/// Type of directive for directiveToken.
	DirectiveType directive;
	/// Used to split value into 2 substrings for tokens that need 2 values (tagToken)
	size_t valueDivider;

	/// Get string representation of the token ID.
	@property string idString() @safe pure const {
		return id.to!string;
	}
}

/// Construct a directive token.
///
/// Params:  start     = Start position of the token.
///          end       = End position of the token.
///          value     = Value of the token.
///          directive = Directive type (YAML or TAG in YAML 1.1).
///          nameEnd   = Beginning index of second value
package Token directiveToken(const Mark start, const Mark end, string value, DirectiveType directive, const size_t nameEnd) @safe pure nothrow @nogc {
	return Token(value, start, end, TokenID.Directive, ScalarStyle.init, directive, nameEnd);
}

/// Construct a simple (no value) token with specified type.
///
/// Params:  id    = Type of the token.
///          start = Start position of the token.
///          end   = End position of the token.
package Token simpleToken(TokenID id)(const Mark start, const Mark end) @safe pure nothrow @nogc {
	return Token(null, start, end, id);
}

/// Construct a stream start token.
///
/// Params:  start    = Start position of the token.
///          end      = End position of the token.
package Token streamStartToken(const Mark start, const Mark end) @safe pure nothrow @nogc {
	return Token(null, start, end, TokenID.StreamStart, ScalarStyle.Invalid);
}

/// Aliases for construction of simple token types.
package alias streamEndToken = simpleToken!(TokenID.StreamEnd);
package alias blockSequenceStartToken = simpleToken!(TokenID.BlockSequenceStart);
package alias blockMappingStartToken = simpleToken!(TokenID.BlockMappingStart);
package alias blockEndToken = simpleToken!(TokenID.BlockEnd);
package alias keyToken = simpleToken!(TokenID.Key);
package alias valueToken = simpleToken!(TokenID.Value);
package alias blockEntryToken = simpleToken!(TokenID.BlockEntry);
package alias flowEntryToken = simpleToken!(TokenID.FlowEntry);

/// Construct a simple token with value with specified type.
///
/// Params:  id           = Type of the token.
///          start        = Start position of the token.
///          end          = End position of the token.
///          value        = Value of the token.
///          valueDivider = A hack for TagToken to store 2 values in value; the first
///                         value goes up to valueDivider, the second after it.
package Token simpleValueToken(TokenID id)(const Mark start, const Mark end, string value, const size_t valueDivider = size_t.max) @safe pure nothrow @nogc {
	return Token(value, start, end, id, ScalarStyle.Invalid, DirectiveType.init, valueDivider);
}

/// Alias for construction of tag token.
package alias tagToken = simpleValueToken!(TokenID.Tag);
package alias aliasToken = simpleValueToken!(TokenID.Alias);
package alias anchorToken = simpleValueToken!(TokenID.Anchor);

/// Construct a scalar token.
///
/// Params:  start = Start position of the token.
///          end   = End position of the token.
///          value = Value of the token.
///          style = Style of the token.
package Token scalarToken(const Mark start, const Mark end, string value, const ScalarStyle style) @safe pure nothrow @nogc {
	return Token(value, start, end, TokenID.Scalar, style);
}

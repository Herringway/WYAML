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


package:

/// Token types.
enum TokenID : ubyte
{
    Invalid = 0,        /// Invalid (uninitialized) token
    Directive,          /// DIRECTIVE
    DocumentStart,      /// DOCUMENT-START
    DocumentEnd,        /// DOCUMENT-END
    StreamStart,        /// STREAM-START
    StreamEnd,          /// STREAM-END
    BlockSequenceStart, /// BLOCK-SEQUENCE-START
    BlockMappingStart,  /// BLOCK-MAPPING-START
    BlockEnd,           /// BLOCK-END
    FlowSequenceStart,  /// FLOW-SEQUENCE-START
    FlowMappingStart,   /// FLOW-MAPPING-START
    FlowSequenceEnd,    /// FLOW-SEQUENCE-END
    FlowMappingEnd,     /// FLOW-MAPPING-END
    Key,                /// KEY
    Value,              /// VALUE
    BlockEntry,         /// BLOCK-ENTRY
    FlowEntry,          /// FLOW-ENTRY
    Alias,              /// ALIAS
    Anchor,             /// ANCHOR
    Tag,                /// TAG
    Scalar              /// SCALAR
}

/// Specifies the type of a tag directive token.
enum DirectiveType : ubyte
{
    // YAML version directive.
    YAML,
    // Tag directive.
    TAG,
    // Any other directive is "reserved" for future YAML versions.
    Reserved
}

/// Token produced by scanner.
///
struct Token
{
    @disable int opCmp(ref Token);

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

@safe pure nothrow @nogc:

/// Construct a directive token.
///
/// Params:  start     = Start position of the token.
///          end       = End position of the token.
///          value     = Value of the token.
///          directive = Directive type (YAML or TAG in YAML 1.1).
///          nameEnd   = Beginning index of second value
Token directiveToken(const Mark start, const Mark end, string value,
                     DirectiveType directive, const size_t nameEnd)
{
    return Token(value, start, end, TokenID.Directive, ScalarStyle.init,
                 directive, nameEnd);
}

/// Construct a simple (no value) token with specified type.
///
/// Params:  id    = Type of the token.
///          start = Start position of the token.
///          end   = End position of the token.
Token simpleToken(TokenID id)(const Mark start, const Mark end)
{
    return Token(null, start, end, id);
}

/// Construct a stream start token.
///
/// Params:  start    = Start position of the token.
///          end      = End position of the token.
Token streamStartToken(const Mark start, const Mark end)
{
    return Token(null, start, end, TokenID.StreamStart, ScalarStyle.Invalid);
}

/// Aliases for construction of simple token types.
alias simpleToken!(TokenID.StreamEnd)          streamEndToken;
alias simpleToken!(TokenID.BlockSequenceStart) blockSequenceStartToken;
alias simpleToken!(TokenID.BlockMappingStart)  blockMappingStartToken;
alias simpleToken!(TokenID.BlockEnd)           blockEndToken;
alias simpleToken!(TokenID.Key)                keyToken;
alias simpleToken!(TokenID.Value)              valueToken;
alias simpleToken!(TokenID.BlockEntry)         blockEntryToken;
alias simpleToken!(TokenID.FlowEntry)          flowEntryToken;

/// Construct a simple token with value with specified type.
///
/// Params:  id           = Type of the token.
///          start        = Start position of the token.
///          end          = End position of the token.
///          value        = Value of the token.
///          valueDivider = A hack for TagToken to store 2 values in value; the first
///                         value goes up to valueDivider, the second after it.
Token simpleValueToken(TokenID id)(const Mark start, const Mark end, string value,
                                   const size_t valueDivider = size_t.max)
{
    return Token(value, start, end, id, ScalarStyle.Invalid,
                 DirectiveType.init, valueDivider);
}

/// Alias for construction of tag token.
alias simpleValueToken!(TokenID.Tag) tagToken;
alias simpleValueToken!(TokenID.Alias) aliasToken;
alias simpleValueToken!(TokenID.Anchor) anchorToken;

/// Construct a scalar token.
///
/// Params:  start = Start position of the token.
///          end   = End position of the token.
///          value = Value of the token.
///          style = Style of the token.
Token scalarToken(const Mark start, const Mark end, string value, const ScalarStyle style)
{
    return Token(value, start, end, TokenID.Scalar, style);
}

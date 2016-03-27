
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// YAML scanner.
/// Code based on PyYAML: http://www.pyyaml.org
module dyaml.scanner;


import core.stdc.string;

import std.algorithm;
import std.array;
import std.container;
import std.conv;
import std.ascii : isAlphaNum, isDigit, isHexDigit;
import std.exception;
import std.meta;
import std.range;
import std.string;
import std.typecons;
import std.traits : Unqual;

import dyaml.escapes;
import dyaml.exception;
import dyaml.nogcutil;
import dyaml.queue;
import dyaml.reader;
import dyaml.style;
import dyaml.token;

package:
/// Scanner produces tokens of the following types:
/// STREAM-START
/// STREAM-END
/// DIRECTIVE(name, value)
/// DOCUMENT-START
/// DOCUMENT-END
/// BLOCK-SEQUENCE-START
/// BLOCK-MAPPING-START
/// BLOCK-END
/// FLOW-SEQUENCE-START
/// FLOW-MAPPING-START
/// FLOW-SEQUENCE-END
/// FLOW-MAPPING-END
/// BLOCK-ENTRY
/// FLOW-ENTRY
/// KEY
/// VALUE
/// ALIAS(value)
/// ANCHOR(value)
/// TAG(value)
/// SCALAR(value, plain, style)

alias newLines = AliasSeq!('\n', '\r', '\u0085', '\u2028', '\u2029');
alias newLinesPlusSpaces = AliasSeq!(newLines, ' ');
alias whiteSpaces = AliasSeq!(' ', '\t');
alias allBreaks = AliasSeq!(newLines, '\0');
alias allWhiteSpace = AliasSeq!(whiteSpaces, allBreaks);
alias allWhiteSpacePlusQuotesAndSlashes = AliasSeq!(allWhiteSpace, '\'', '"', '\\');
alias chompIndicators = AliasSeq!('+', '-');
alias curlyBraces = AliasSeq!('{', '}');
alias squareBrackets = AliasSeq!('[', ']');
alias parentheses = AliasSeq!('(', ')');

/// Marked exception thrown at scanner errors.
///
/// See_Also: MarkedYAMLException
class ScannerException : MarkedYAMLException
{
    mixin MarkedExceptionCtors;
}
class UnexpectedTokenException : YAMLException {
    this(string context, in Mark begin, in Mark end, string expected, dchar got, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super("Expected %s in %s, got %s".format(expected, context, got), file, line);
    }
}
class UnexpectedSequenceException : YAMLException {
    this(string context, in Mark begin, in Mark end, string unexpected, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super("Found unexpected %s in %s".format(unexpected, context), file, line);
    }
}

/// Generates tokens from data provided by a Reader.
final class Scanner
{
    private:
        /// A simple key is a key that is not denoted by the '?' indicator.
        /// For example:
        ///   ---
        ///   block simple key: value
        ///   ? not a simple key:
        ///   : { flow simple key: value }
        /// We emit the KEY token before all keys, so when we find a potential simple
        /// key, we try to locate the corresponding ':' indicator. Simple keys should be
        /// limited to a single line and 1024 characters.
        ///
        /// 16 bytes on 64-bit.
        static struct SimpleKey
        {
            /// Index of the key token from start (first token scanned being 0).
            uint tokenIndex;
            /// Line the key starts at.
            uint line;
            /// Column the key starts at.
            ushort column;
            /// Is this required to be a simple key?
            bool required;
            /// Is this struct "null" (invalid)?.
            bool isNull;
        }

        /// Block chomping types.
        enum Chomping
        {
            /// Strip all trailing line breaks. '-' indicator.
            Strip,
            /// Line break of the last line is preserved, others discarded. Default.
            Clip,
            /// All trailing line breaks are preserved. '+' indicator.
            Keep
        }

        /// Reader used to read from a file/stream.
        Reader reader_;
        /// Are we done scanning?
        bool done_;

        /// Level of nesting in flow context. If 0, we're in block context.
        uint flowLevel_;
        /// Current indentation level.
        int indent_ = -1;
        /// Past indentation levels. Used as a stack.
        Array!int indents_;

        /// Processed tokens not yet emitted. Used as a queue.
        Queue!Token tokens_;

        /// Number of tokens emitted through the getToken method.
        uint tokensTaken_;

        /// Can a simple key start at the current position? A simple key may start:
        /// - at the beginning of the line, not counting indentation spaces
        ///       (in block context),
        /// - after '{', '[', ',' (in the flow context),
        /// - after '?', ':', '-' (in the block context).
        /// In the block context, this flag also signifies if a block collection
        /// may start at the current position.
        bool allowSimpleKey_ = true;

        /// Possible simple keys indexed by flow levels.
        SimpleKey[] possibleSimpleKeys_;

    public:
        /// Construct a Scanner using specified Reader.
        this(Reader reader) @safe nothrow
        {
            // Return the next token, but do not delete it from the queue
            reader_   = reader;
            fetchStreamStart();
        }

        /// Check if the next token is one of specified types.
        ///
        /// If no types are specified, checks if any tokens are left.
        ///
        /// Params:  ids = Token IDs to check for.
        ///
        /// Returns: true if the next token is one of specified types, or if there are
        ///          any tokens left if no types specified, false otherwise.
        bool checkToken(const TokenID[] ids ...) @safe
        {
            // Check if the next token is one of specified types.
            while(needMoreTokens()) { fetchToken(); }
            if(!tokens_.empty)
            {
                if(ids.length == 0) { return true; }
                else
                {
                    const nextId = tokens_.peek().id;
                    foreach(id; ids)
                    {
                        if(nextId == id) { return true; }
                    }
                }
            }
            return false;
        }

        /// Return the next token, but keep it in the queue.
        ///
        /// Must not be called if there are no tokens left.
        ref const(Token) peekToken() @safe
        {
            while(needMoreTokens) { fetchToken(); }
            if(!tokens_.empty)    { return tokens_.peek(); }
            assert(false, "No token left to peek");
        }

        /// Return the next token, removing it from the queue.
        ///
        /// Must not be called if there are no tokens left.
        Token getToken() @safe
        {
            while(needMoreTokens){fetchToken();}
            if(!tokens_.empty)
            {
                ++tokensTaken_;
                return tokens_.pop();
            }
            assert(false, "No token left to get");
        }

    private:
        /// Determine whether or not we need to fetch more tokens before peeking/getting a token.
        bool needMoreTokens() @safe pure
        {
            if(done_)         { return false; }
            if(tokens_.empty) { return true; }

            /// The current token may be a potential simple key, so we need to look further.
            stalePossibleSimpleKeys();
            return nextPossibleSimpleKey() == tokensTaken_;
        }

        /// Fetch at token, adding it to tokens_.
        void fetchToken() @safe
        {
            // Eat whitespaces and comments until we reach the next token.
            scanToNextToken();

            // Remove obsolete possible simple keys.
            stalePossibleSimpleKeys();

            // Compare current indentation and column. It may add some tokens
            // and decrease the current indentation level.
            unwindIndent(reader_.column);

            // Get the next character.
            const dchar c = reader_.front;

            // Fetch the token.
            if(c == '\0')            { return fetchStreamEnd();     }
            if(checkDirective())     { return fetchDirective();     }
            if(checkDocumentStart()) { return fetchDocumentStart(); }
            if(checkDocumentEnd())   { return fetchDocumentEnd();   }
            // Order of the following checks is NOT significant.
            switch(c)
            {
                case '[':  return fetchFlowSequenceStart();
                case '{':  return fetchFlowMappingStart();
                case ']':  return fetchFlowSequenceEnd();
                case '}':  return fetchFlowMappingEnd();
                case ',':  return fetchFlowEntry();
                case '!':  return fetchTag();
                case '\'': return fetchSingle();
                case '\"': return fetchDouble();
                case '*':  return fetchAlias();
                case '&':  return fetchAnchor();
                case '?':  if(checkKey())        { return fetchKey();        } goto default;
                case ':':  if(checkValue())      { return fetchValue();      } goto default;
                case '-':  if(checkBlockEntry()) { return fetchBlockEntry(); } goto default;
                case '|':  if(flowLevel_ == 0)   { return fetchLiteral();    } break;
                case '>':  if(flowLevel_ == 0)   { return fetchFolded();     } break;
                default:   if(checkPlain())      { return fetchPlain();      }
            }

            throw new ScannerException("While scanning for the next token, found character "
                                       "\'%s\', index %s that cannot start any token"
                                       .format(c, to!int(c)), reader_.mark);
        }


        /// Return the token number of the nearest possible simple key.
        uint nextPossibleSimpleKey() @safe pure nothrow @nogc
        {
            uint minTokenNumber = uint.max;
            foreach(k, ref simpleKey; possibleSimpleKeys_)
            {
                if(simpleKey.isNull) { continue; }
                minTokenNumber = min(minTokenNumber, simpleKey.tokenIndex);
            }
            return minTokenNumber;
        }

        /// Remove entries that are no longer possible simple keys.
        ///
        /// According to the YAML specification, simple keys
        /// - should be limited to a single line,
        /// - should be no longer than 1024 characters.
        /// Disabling this will allow simple keys of any length and
        /// height (may cause problems if indentation is broken though).
        void stalePossibleSimpleKeys() @safe pure
        {
            foreach(level, ref key; possibleSimpleKeys_)
            {
                if(key.isNull) { continue; }
                if(key.line != reader_.line)
                {
                    enforce(!key.required,
                            new ScannerException("While scanning a simple key",
                                                 Mark(key.line, key.column),
                                                 "could not find expected ':'", reader_.mark));
                    key.isNull = true;
                }
            }
        }

        /// Check if the next token starts a possible simple key and if so, save its position.
        ///
        /// This function is called for ALIAS, ANCHOR, TAG, SCALAR(flow), '[', and '{'.
        void savePossibleSimpleKey() @safe pure
        {
            // Check if a simple key is required at the current position.
            const required = (flowLevel_ == 0 && indent_ == reader_.column);
            assert(allowSimpleKey_ || !required, "A simple key is required only if it is "
                   "the first token in the current line. Therefore it is always allowed.");

            if(!allowSimpleKey_) { return; }

            // The next token might be a simple key, so save its number and position.
            removePossibleSimpleKey();
            const tokenCount = tokensTaken_ + cast(uint)tokens_.length;

            const line   = reader_.line;
            const column = reader_.column;
            const key    = SimpleKey(tokenCount, line,
                                     cast(ushort)min(column, ushort.max), required);

            if(possibleSimpleKeys_.length <= flowLevel_)
            {
                const oldLength = possibleSimpleKeys_.length;
                possibleSimpleKeys_.length = flowLevel_ + 1;
                //No need to initialize the last element, it's already done in the next line.
                possibleSimpleKeys_[oldLength .. flowLevel_] = SimpleKey.init;
            }
            possibleSimpleKeys_[flowLevel_] = key;
        }

        /// Remove the saved possible key position at the current flow level.
        void removePossibleSimpleKey() @safe pure
        {
            if(possibleSimpleKeys_.length <= flowLevel_) { return; }

            if(!possibleSimpleKeys_[flowLevel_].isNull)
            {
                const key = possibleSimpleKeys_[flowLevel_];
                enforce(!key.required,
                        new ScannerException("While scanning a simple key",
                                             Mark(key.line, key.column),
                                             "could not find expected ':'", reader_.mark));
                possibleSimpleKeys_[flowLevel_].isNull = true;
            }
        }

        /// Decrease indentation, removing entries in indents_.
        ///
        /// Params:  column = Current column in the file/stream.
        void unwindIndent(const int column) @trusted
        {
            if(flowLevel_ > 0)
            {
                // In flow context, tokens should respect indentation.
                // The condition should be `indent >= column` according to the spec.
                // But this condition will prohibit intuitively correct
                // constructions such as
                // key : {
                // }

                // In the flow context, indentation is ignored. We make the scanner less
                // restrictive than what the specification requires.
                // if(pedantic_ && flowLevel_ > 0 && indent_ > column)
                // {
                //     throw new ScannerException("Invalid intendation or unclosed '[' or '{'",
                //                                reader_.mark)
                // }
                return;
            }

            // In block context, we may need to issue the BLOCK-END tokens.
            while(indent_ > column)
            {
                indent_ = indents_.back;
                indents_.length = indents_.length - 1;
                tokens_.push(blockEndToken(reader_.mark, reader_.mark));
            }
        }

        /// Increase indentation if needed.
        ///
        /// Params:  column = Current column in the file/stream.
        ///
        /// Returns: true if the indentation was increased, false otherwise.
        bool addIndent(int column) @trusted
        {
            if(indent_ >= column){return false;}
            indents_ ~= indent_;
            indent_ = column;
            return true;
        }


        /// Add STREAM-START token.
        void fetchStreamStart() @safe nothrow
        {
            tokens_.push(streamStartToken(reader_.mark, reader_.mark));
        }

        ///Add STREAM-END token.
        void fetchStreamEnd() @safe
        {
            //Set intendation to -1 .
            unwindIndent(-1);
            removePossibleSimpleKey();
            allowSimpleKey_ = false;
            possibleSimpleKeys_.destroy;

            tokens_.push(streamEndToken(reader_.mark, reader_.mark));
            done_ = true;
        }

        /// Add DIRECTIVE token.
        void fetchDirective() @safe
        {
            // Set intendation to -1 .
            unwindIndent(-1);
            // Reset simple keys.
            removePossibleSimpleKey();
            allowSimpleKey_ = false;

            auto directive = scanDirective();
            tokens_.push(directive);
        }

        /// Add DOCUMENT-START or DOCUMENT-END token.
        void fetchDocumentIndicator(TokenID id)() @safe
            if(id == TokenID.DocumentStart || id == TokenID.DocumentEnd)
        {
            // Set indentation to -1 .
            unwindIndent(-1);
            // Reset simple keys. Note that there can't be a block collection after '---'.
            removePossibleSimpleKey();
            allowSimpleKey_ = false;

            Mark startMark = reader_.mark;
            reader_.popFrontN(3);
            tokens_.push(simpleToken!id(startMark, reader_.mark));
        }

        /// Aliases to add DOCUMENT-START or DOCUMENT-END token.
        alias fetchDocumentIndicator!(TokenID.DocumentStart) fetchDocumentStart;
        alias fetchDocumentIndicator!(TokenID.DocumentEnd) fetchDocumentEnd;

        /// Add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
        void fetchFlowCollectionStart(TokenID id)() @trusted
        {
            // '[' and '{' may start a simple key.
            savePossibleSimpleKey();
            // Simple keys are allowed after '[' and '{'.
            allowSimpleKey_ = true;
            ++flowLevel_;

            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(simpleToken!id(startMark, reader_.mark));
        }

        /// Aliases to add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
        alias fetchFlowCollectionStart!(TokenID.FlowSequenceStart) fetchFlowSequenceStart;
        alias fetchFlowCollectionStart!(TokenID.FlowMappingStart) fetchFlowMappingStart;

        /// Add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
        void fetchFlowCollectionEnd(TokenID id)() @safe
        {
            // Reset possible simple key on the current level.
            removePossibleSimpleKey();
            // No simple keys after ']' and '}'.
            allowSimpleKey_ = false;
            --flowLevel_;

            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(simpleToken!id(startMark, reader_.mark));
        }

        /// Aliases to add FLOW-SEQUENCE-START or FLOW-MAPPING-START token/
        alias fetchFlowCollectionEnd!(TokenID.FlowSequenceEnd) fetchFlowSequenceEnd;
        alias fetchFlowCollectionEnd!(TokenID.FlowMappingEnd) fetchFlowMappingEnd;

        /// Add FLOW-ENTRY token;
        void fetchFlowEntry() @safe
        {
            // Reset possible simple key on the current level.
            removePossibleSimpleKey();
            // Simple keys are allowed after ','.
            allowSimpleKey_ = true;

            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(flowEntryToken(startMark, reader_.mark));
        }

        /// Additional checks used in block context in fetchBlockEntry and fetchKey.
        ///
        /// Params:  type = String representing the token type we might need to add.
        ///          id   = Token type we might need to add.
        void blockChecks(string type, TokenID id)() @safe
        {
            enum context = type ~ " keys are not allowed here";
            // Are we allowed to start a key (not neccesarily a simple one)?
            enforce(allowSimpleKey_, new ScannerException(context, reader_.mark));

            if(addIndent(reader_.column))
            {
                tokens_.push(simpleToken!id(reader_.mark, reader_.mark));
            }
        }

        /// Add BLOCK-ENTRY token. Might add BLOCK-SEQUENCE-START in the process.
        void fetchBlockEntry() @safe
        {
            if(flowLevel_ == 0) { blockChecks!("Sequence", TokenID.BlockSequenceStart)(); }

            // It's an error for the block entry to occur in the flow context,
            // but we let the parser detect this.

            // Reset possible simple key on the current level.
            removePossibleSimpleKey();
            // Simple keys are allowed after '-'.
            allowSimpleKey_ = true;

            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(blockEntryToken(startMark, reader_.mark));
        }

        /// Add KEY token. Might add BLOCK-MAPPING-START in the process.
        void fetchKey() @safe
        {
            if(flowLevel_ == 0) { blockChecks!("Mapping", TokenID.BlockMappingStart)(); }

            // Reset possible simple key on the current level.
            removePossibleSimpleKey();
            // Simple keys are allowed after '?' in the block context.
            allowSimpleKey_ = (flowLevel_ == 0);

            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(keyToken(startMark, reader_.mark));
        }

        /// Add VALUE token. Might add KEY and/or BLOCK-MAPPING-START in the process.
        void fetchValue() @safe
        {
            //Do we determine a simple key?
            if(possibleSimpleKeys_.length > flowLevel_ &&
               !possibleSimpleKeys_[flowLevel_].isNull)
            {
                const key = possibleSimpleKeys_[flowLevel_];
                possibleSimpleKeys_[flowLevel_].isNull = true;
                Mark keyMark = Mark(key.line, key.column);
                const idx = key.tokenIndex - tokensTaken_;

                assert(idx >= 0);

                // Add KEY.
                // Manually inserting since tokens are immutable (need linked list).
                tokens_.insert(keyToken(keyMark, keyMark), idx);

                // If this key starts a new block mapping, we need to add BLOCK-MAPPING-START.
                if(flowLevel_ == 0 && addIndent(key.column))
                {
                    tokens_.insert(blockMappingStartToken(keyMark, keyMark), idx);
                }

                // There cannot be two simple keys in a row.
                allowSimpleKey_ = false;
            }
            // Part of a complex key
            else
            {
                // We can start a complex value if and only if we can start a simple key.
                enforce(flowLevel_ > 0 || allowSimpleKey_,
                        new ScannerException("Mapping values are not allowed here", reader_.mark));

                // If this value starts a new block mapping, we need to add
                // BLOCK-MAPPING-START. It'll be detected as an error later by the parser.
                if(flowLevel_ == 0 && addIndent(reader_.column))
                {
                    tokens_.push(blockMappingStartToken(reader_.mark, reader_.mark));
                }

                // Reset possible simple key on the current level.
                removePossibleSimpleKey();
                // Simple keys are allowed after ':' in the block context.
                allowSimpleKey_ = (flowLevel_ == 0);
            }

            // Add VALUE.
            Mark startMark = reader_.mark;
            reader_.popFront();
            tokens_.push(valueToken(startMark, reader_.mark));
        }

        /// Add ALIAS or ANCHOR token.
        void fetchAnchor_(TokenID id)() @trusted
            if(id == TokenID.Alias || id == TokenID.Anchor)
        {
            // ALIAS/ANCHOR could be a simple key.
            savePossibleSimpleKey();
            // No simple keys after ALIAS/ANCHOR.
            allowSimpleKey_ = false;

            auto anchor = scanAnchor(id);
            tokens_.push(anchor);
        }

        /// Aliases to add ALIAS or ANCHOR token.
        alias fetchAnchor_!(TokenID.Alias) fetchAlias;
        alias fetchAnchor_!(TokenID.Anchor) fetchAnchor;

        /// Add TAG token.
        void fetchTag() @trusted
        {
            //TAG could start a simple key.
            savePossibleSimpleKey();
            //No simple keys after TAG.
            allowSimpleKey_ = false;

            tokens_.push(scanTag());
        }

        /// Add block SCALAR token.
        void fetchBlockScalar(ScalarStyle style)() @trusted
            if(style == ScalarStyle.Literal || style == ScalarStyle.Folded)
        {
            // Reset possible simple key on the current level.
            removePossibleSimpleKey();
            // A simple key may follow a block scalar.
            allowSimpleKey_ = true;

            auto blockScalar = scanBlockScalar(style);
            tokens_.push(blockScalar);
        }

        /// Aliases to add literal or folded block scalar.
        alias fetchBlockScalar!(ScalarStyle.Literal) fetchLiteral;
        alias fetchBlockScalar!(ScalarStyle.Folded) fetchFolded;

        /// Add quoted flow SCALAR token.
        void fetchFlowScalar(ScalarStyle quotes)() @safe
        {
            // A flow scalar could be a simple key.
            savePossibleSimpleKey();
            // No simple keys after flow scalars.
            allowSimpleKey_ = false;

            // Scan and add SCALAR.
            auto scalar = scanFlowScalar(quotes);
            tokens_.push(scalar);
        }

        /// Aliases to add single or double quoted block scalar.
        alias fetchFlowScalar!(ScalarStyle.SingleQuoted) fetchSingle;
        alias fetchFlowScalar!(ScalarStyle.DoubleQuoted) fetchDouble;

        /// Add plain SCALAR token.
        void fetchPlain() @safe
        {
            // A plain scalar could be a simple key
            savePossibleSimpleKey();
            // No simple keys after plain scalars. But note that scanPlain() will
            // change this flag if the scan is finished at the beginning of the line.
            allowSimpleKey_ = false;
            auto plain = scanPlain();

            // Scan and add SCALAR. May change allowSimpleKey_
            tokens_.push(plain);
        }

        ///Check if the next token is DIRECTIVE:        ^ '%' ...
        bool checkDirective() @safe
        {
            return reader_.front == '%' && reader_.column == 0;
        }

        /// Check if the next token is DOCUMENT-START:   ^ '---' (' '|'\n')
        bool checkDocumentStart() @safe
        {
            return checkSequence!"---";
        }

        /// Check if the next token is DOCUMENT-END:     ^ '...' (' '|'\n')
        bool checkDocumentEnd() @safe
        {
            return checkSequence!"...";
        }
        bool checkSequence(string T)() @safe
        {
            if (reader_.column != 0)
                return false;
            if (reader_.empty)
                return false;
            auto readerCopy = reader_.save();
            if (!readerCopy.startsWith(T))
                return false;
            readerCopy.popFront();
            if (!readerCopy.front.among!allWhiteSpace)
                return false;
            return true;
        }

        /// Check if the next token is BLOCK-ENTRY:      '-' (' '|'\n')
        bool checkBlockEntry() @safe
        {
            return !!reader_.save().drop(1).front.among!(allWhiteSpace);
        }

        /// Check if the next token is KEY(flow context):    '?'
        ///
        /// or KEY(block context):   '?' (' '|'\n')
        bool checkKey() @safe
        {
            return flowLevel_ > 0 || reader_.save().drop(1).front.among!(allWhiteSpace);
        }

        /// Check if the next token is VALUE(flow context):  ':'
        ///
        /// or VALUE(block context): ':' (' '|'\n')
        bool checkValue() @safe
        {
            return flowLevel_ > 0 || reader_.save().drop(1).front.among!(allWhiteSpace);
        }

        /// Check if the next token is a plain scalar.
        ///
        /// A plain scalar may start with any non-space character except:
        ///   '-', '?', ':', ',', '[', ']', '{', '}',
        ///   '#', '&', '*', '!', '|', '>', '\'', '\"',
        ///   '%', '@', '`'.
        ///
        /// It may also start with
        ///   '-', '?', ':'
        /// if it is followed by a non-space character.
        ///
        /// Note that we limit the last rule to the block context (except the
        /// '-' character) because we want the flow context to be space
        /// independent.
        bool checkPlain() @safe
        {
            const c = reader_.front;
            if(!c.among!(allWhiteSpacePlusQuotesAndSlashes, curlyBraces, squareBrackets, '-', '?', ',', '#', '&', '*', '!', '|', '>', '%', '@', '`'))
            {
                return true;
            }
            return !reader_.save().drop(1).front.among!(allWhiteSpace) &&
                   (c == '-' || (flowLevel_ == 0 && c.among!('?', ':')));
        }

        /// Move to the next non-space character.
        void findNextNonSpace() @safe
        {
            while(!reader_.empty && reader_.skipOver(' ')) {}
        }

        /// Scan a string of alphanumeric or "-_" characters.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanAlphaNumericToSlice(string name)(const Mark startMark) @system
        {
            size_t length = 0;
            dchar c = reader_.front;
            while(c.isAlphaNum || c.among!('-', '_')) { c = reader_.save().drop(++length).front; }

            enforce(length != 0, new UnexpectedTokenException(name, startMark, reader_.mark, "alphanumeric, '-', or '_'", c));

            reader_.sliceBuilder.write(reader_.take(length).array);
        }

        /// Scan and throw away all characters until next line break.
        void scanToNextBreak() @safe
        {
            while(!reader_.startsWith(allBreaks)) { reader_.popFront(); }
        }

        /// Scan all characters until next line break.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanToNextBreakToSlice() @system
        {
            uint length = 0;
            while(!reader_.save().drop(length).front.among!(allBreaks))
            {
                ++length;
            }
            reader_.sliceBuilder.write(reader_.take(length).array);
        }


        /// Move to next token in the file/stream.
        ///
        /// We ignore spaces, line breaks and comments.
        /// If we find a line break in the block context, we set
        /// allowSimpleKey` on.
        ///
        /// We do not yet support BOM inside the stream as the
        /// specification requires. Any such mark will be considered as a part
        /// of the document.
        void scanToNextToken() @safe
        {
            // TODO(PyYAML): We need to make tab handling rules more sane. A good rule is:
            //   Tabs cannot precede tokens
            //   BLOCK-SEQUENCE-START, BLOCK-MAPPING-START, BLOCK-END,
            //   KEY(block), VALUE(block), BLOCK-ENTRY
            // So the checking code is
            //   if <TAB>:
            //       allowSimpleKey_ = false
            // We also need to add the check for `allowSimpleKey_ == true` to
            // `unwindIndent` before issuing BLOCK-END.
            // Scanners for block, flow, and plain scalars need to be modified.

            for(;;)
            {
                findNextNonSpace();

                if(reader_.front == '#') { scanToNextBreak(); }
                if(scanLineBreak() != '\0')
                {
                    if(flowLevel_ == 0) { allowSimpleKey_ = true; }
                }
                else
                {
                    break;
                }
            }
        }

        /// Scan directive token.
        Token scanDirective() @trusted
        {
            Mark startMark = reader_.mark;
            // Skip the '%'.
            reader_.popFront();

            // Scan directive name
            reader_.sliceBuilder.begin();
            scanDirectiveNameToSlice(startMark);

            const name = reader_.sliceBuilder.finish();

            reader_.sliceBuilder.begin();

            // Index where tag handle ends and suffix starts in a tag directive value.
            uint tagHandleEnd = uint.max;
            if(name == "YAML")     { scanYAMLDirectiveValueToSlice(startMark); }
            else if(name == "TAG") { tagHandleEnd = scanTagDirectiveValueToSlice(startMark); }
            char[] value = reader_.sliceBuilder.finish();

            Mark endMark = reader_.mark;

            DirectiveType directive;
            if(name == "YAML")     { directive = DirectiveType.YAML; }
            else if(name == "TAG") { directive = DirectiveType.TAG; }
            else
            {
                directive = DirectiveType.Reserved;
                scanToNextBreak();
            }

            scanDirectiveIgnoredLine(startMark);

            return directiveToken(startMark, endMark, value, directive, tagHandleEnd);
        }

        /// Scan name of a directive token.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanDirectiveNameToSlice(const Mark startMark) @system
        {
            // Scan directive name.
            scanAlphaNumericToSlice!"a directive"(startMark);
            enforce(reader_.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", startMark, reader_.mark, "alphanumeric, '-' or '_'", reader_.front));
        }

        /// Scan value of a YAML directive token. Returns major, minor version separated by '.'.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanYAMLDirectiveValueToSlice(const Mark startMark) @system
        {
            findNextNonSpace();

            scanYAMLDirectiveNumberToSlice(startMark);

            enforce(reader_.front == '.', new UnexpectedTokenException("directive", startMark, reader_.mark, "digit or '.'", reader_.front));
            // Skip the '.'.
            reader_.popFront();

            reader_.sliceBuilder.write('.');
            scanYAMLDirectiveNumberToSlice(startMark);

            enforce(reader_.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", startMark, reader_.mark, "digit or '.'", reader_.front));
        }

        /// Scan a number from a YAML directive.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanYAMLDirectiveNumberToSlice(const Mark startMark) @system
        {
            enforce(reader_.front.isDigit, new UnexpectedTokenException("directive", startMark, reader_.mark, "digit", reader_.front));
            while (reader_.front.isDigit) {
                reader_.sliceBuilder.write(reader_.front);
                reader_.popFront();
            }
        }

        /// Scan value of a tag directive.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        ///
        /// Returns: Length of tag handle (which is before tag prefix) in scanned data
        uint scanTagDirectiveValueToSlice(const Mark startMark) @system
        {
            findNextNonSpace();
            const startLength = reader_.sliceBuilder.length;
            scanTagDirectiveHandleToSlice(startMark);
            const handleLength = cast(uint)(reader_.sliceBuilder.length  - startLength);
            findNextNonSpace();
            scanTagDirectivePrefixToSlice(startMark);

            return handleLength;
        }

        /// Scan handle of a tag directive.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanTagDirectiveHandleToSlice(const Mark startMark) @system
        {
            scanTagHandleToSlice!"directive"(startMark);
            enforce(reader_.front == ' ', new UnexpectedTokenException("directive", startMark, reader_.mark, "' '", reader_.front));
        }

        /// Scan prefix of a tag directive.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanTagDirectivePrefixToSlice(const Mark startMark) @system
        {
            scanTagURIToSlice!"directive"(startMark);
            enforce(reader_.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", startMark, reader_.mark, "' '", reader_.front));
        }

        /// Scan (and ignore) ignored line after a directive.
        void scanDirectiveIgnoredLine(const Mark startMark) @safe
        {
            findNextNonSpace();
            if(reader_.front == '#') { scanToNextBreak(); }
            enforce(reader_.front.among!(allBreaks), new UnexpectedTokenException("directive", startMark, reader_.mark, "comment or a line break", reader_.front));
            scanLineBreak();
        }


        /// Scan an alias or an anchor.
        ///
        /// The specification does not restrict characters for anchors and
        /// aliases. This may lead to problems, for instance, the document:
        ///   [ *alias, value ]
        /// can be interpteted in two ways, as
        ///   [ "value" ]
        /// and
        ///   [ *alias , "value" ]
        /// Therefore we restrict aliases to ASCII alphanumeric characters.
        Token scanAnchor(const TokenID id) @trusted
        {
            const startMark = reader_.mark;
            const dchar i = reader_.front;
            reader_.popFront();

            reader_.sliceBuilder.begin();
            if(i == '*') { scanAlphaNumericToSlice!"an alias"(startMark); }
            else         { scanAlphaNumericToSlice!"an anchor"(startMark); }

            enforce(reader_.front.among!(allWhiteSpace, '?', ':', ',', ']', '}', '%', '@'), new UnexpectedTokenException(i == '*' ? "alias" : "anchor", startMark, reader_.mark, "alphanumeric, '-' or '_'", reader_.front));

            char[] value = reader_.sliceBuilder.finish();
            switch(id) {
                case TokenID.Alias:
                    return aliasToken(startMark, reader_.mark, value);
                case TokenID.Anchor:
                    return anchorToken(startMark, reader_.mark, value);
                default:
                    assert(false, "Invalid token reached");
            }
        }

        /// Scan a tag token.
        Token scanTag() @trusted
        {
            const startMark = reader_.mark;
            dchar c = reader_.save().drop(1).front;

            reader_.sliceBuilder.begin();
            scope(failure) { reader_.sliceBuilder.finish(); }
            // Index where tag handle ends and tag suffix starts in the tag value
            // (slice) we will produce.
            uint handleEnd;

            if(c == '<')
            {
                reader_.popFrontN(2);

                handleEnd = 0;
                scanTagURIToSlice!"tag"(startMark);
                enforce(reader_.front == '>', new UnexpectedTokenException("tag", startMark, reader_.mark, "'>'", reader_.front));
                reader_.popFront();
            }
            else if(c.among!(allWhiteSpace))
            {
                reader_.popFront();
                handleEnd = 0;
                reader_.sliceBuilder.write('!');
            }
            else
            {
                uint length = 1;
                bool useHandle = false;

                while(!c.among!(allWhiteSpace))
                {
                    if(c == '!')
                    {
                        useHandle = true;
                        break;
                    }
                    ++length;
                    c = reader_.save().drop(length).front;
                }

                if(useHandle)
                {
                    scanTagHandleToSlice!"tag"(startMark);
                    handleEnd = cast(uint)reader_.sliceBuilder.length;
                }
                else
                {
                    reader_.popFront();
                    reader_.sliceBuilder.write('!');
                    handleEnd = cast(uint)reader_.sliceBuilder.length;
                }

                scanTagURIToSlice!"tag"(startMark);
            }

            enforce(reader_.front.among!(allWhiteSpace), new UnexpectedTokenException("tag", startMark, reader_.mark, "' '", reader_.front));

            char[] slice = reader_.sliceBuilder.finish();
            return tagToken(startMark, reader_.mark, slice, handleEnd);
        }

        /// Scan a block scalar token with specified style.
        Token scanBlockScalar(const ScalarStyle style) @trusted
        {
            const startMark = reader_.mark;

            // Scan the header.
            reader_.popFront();

            const indicators = scanBlockScalarIndicators(startMark);

            const chomping   = indicators[0];
            const increment  = indicators[1];
            scanBlockScalarIgnoredLine(startMark);

            // Determine the indentation level and go to the first non-empty line.
            Mark endMark;
            uint indent = max(1, indent_ + 1);

            reader_.sliceBuilder.begin();
            alias Transaction = SliceBuilder.Transaction;
            // Used to strip the last line breaks written to the slice at the end of the
            // scalar, which may be needed based on chomping.
            Transaction breaksTransaction = Transaction(reader_.sliceBuilder);
            // Read the first indentation/line breaks before the scalar.
            size_t startLen = reader_.sliceBuilder.length;
            if(increment == int.min)
            {
                auto indentation = scanBlockScalarIndentationToSlice();
                endMark = indentation[1];
                indent  = max(indent, indentation[0]);
            }
            else
            {
                indent += increment - 1;
                endMark = scanBlockScalarBreaksToSlice(indent);
            }

            // int.max means there's no line break (int.max is outside UTF-32).
            dchar lineBreak = cast(dchar)int.max;

            // Scan the inner part of the block scalar.
            while(reader_.column == indent && reader_.front != '\0')
            {
                breaksTransaction.commit();
                const bool leadingNonSpace = !reader_.front.among!(whiteSpaces);
                // This is where the 'interesting' non-whitespace data gets read.
                scanToNextBreakToSlice();
                lineBreak = scanLineBreak();


                // This transaction serves to rollback data read in the
                // scanBlockScalarBreaksToSlice() call.
                breaksTransaction = Transaction(reader_.sliceBuilder);
                startLen = reader_.sliceBuilder.length;
                // The line breaks should actually be written _after_ the if() block
                // below. We work around that by inserting
                endMark = scanBlockScalarBreaksToSlice(indent);

                // This will not run during the last iteration (see the if() vs the
                // while()), hence breaksTransaction rollback (which happens after this
                // loop) will never roll back data written in this if() block.
                if(reader_.column == indent && reader_.front != '\0')
                {
                    // Unfortunately, folding rules are ambiguous.

                    // This is the folding according to the specification:
                    if(style == ScalarStyle.Folded && lineBreak == '\n' &&
                       leadingNonSpace && !reader_.front.among!(whiteSpaces))
                    {
                        // No breaks were scanned; no need to insert the space in the
                        // middle of slice.
                        if(startLen == reader_.sliceBuilder.length)
                        {
                            reader_.sliceBuilder.write(' ');
                        }
                    }
                    else
                    {
                        // We need to insert in the middle of the slice in case any line
                        // breaks were scanned.
                        reader_.sliceBuilder.insert(lineBreak, startLen);
                    }

                    ////this is Clark Evans's interpretation (also in the spec
                    ////examples):
                    //
                    //if(style == ScalarStyle.Folded && lineBreak == '\n')
                    //{
                    //    if(startLen == endLen)
                    //    {
                    //        if(!reader_.front.among!(' ', '\t'))
                    //        {
                    //            reader_.sliceBuilder.write(' ');
                    //        }
                    //        else
                    //        {
                    //            chunks ~= lineBreak;
                    //        }
                    //    }
                    //}
                    //else
                    //{
                    //    reader_.sliceBuilder.insertBack(lineBreak, endLen - startLen);
                    //}
                }
                else
                {
                    break;
                }
            }

            // If chompint is Keep, we keep (commit) the last scanned line breaks
            // (which are at the end of the scalar). Otherwise re remove them (end the
            // transaction).
            if(chomping == Chomping.Keep)  { breaksTransaction.commit(); }
            else                           { breaksTransaction.__dtor(); }
            if(chomping != Chomping.Strip && lineBreak != int.max)
            {
                // If chomping is Keep, we keep the line break but the first line break
                // that isn't stripped (since chomping isn't Strip in this branch) must
                // be inserted _before_ the other line breaks.
                if(chomping == Chomping.Keep)
                {
                    reader_.sliceBuilder.insert(lineBreak, startLen);
                }
                // If chomping is not Keep, breaksTransaction was cancelled so we can
                // directly write the first line break (as it isn't stripped - chomping
                // is not Strip)
                else
                {
                    reader_.sliceBuilder.write(lineBreak);
                }
            }

            char[] slice = reader_.sliceBuilder.finish();
            return scalarToken(startMark, endMark, slice, style);
        }

        /// Scan chomping and indentation indicators of a scalar token.
        Tuple!(Chomping, int) scanBlockScalarIndicators(const Mark startMark) @safe
        {
            auto chomping = Chomping.Clip;
            int increment = int.min;
            dchar c       = reader_.front;

            /// Indicators can be in any order.
            if(getChomping(c, chomping))
            {
                getIncrement(c, increment, startMark);
            }
            else
            {
                const gotIncrement = getIncrement(c, increment, startMark);
                if(gotIncrement) { getChomping(c, chomping); }
            }

            enforce(c.among!(allWhiteSpace), new UnexpectedTokenException("block scalar", startMark, reader_.mark, "chomping or indentation indicator", c));

            return tuple(chomping, increment);
        }

        /// Get chomping indicator, if detected. Return false otherwise.
        ///
        /// Used in scanBlockScalarIndicators.
        ///
        /// Params:
        ///
        /// c        = The character that may be a chomping indicator.
        /// chomping = Write the chomping value here, if detected.
        bool getChomping(ref dchar c, ref Chomping chomping) @safe
        {
            if(!c.among!(chompIndicators)) { return false; }
            chomping = c == '+' ? Chomping.Keep : Chomping.Strip;
            reader_.popFront();
            c = reader_.front;
            return true;
        }

        /// Get increment indicator, if detected. Return false otherwise.
        ///
        /// Used in scanBlockScalarIndicators.
        ///
        /// Params:
        ///
        /// c         = The character that may be an increment indicator.
        ///             If an increment indicator is detected, this will be updated to
        ///             the next character in the Reader.
        /// increment = Write the increment value here, if detected.
        /// startMark = Mark for error messages.
        bool getIncrement(ref dchar c, ref int increment, const Mark startMark) @safe
        {
            if(!c.isDigit) { return false; }
            // Convert a digit to integer.
            increment = c - '0';
            assert(increment < 10 && increment >= 0, "Digit has invalid value");
            enforce(increment > 0, new UnexpectedTokenException("block scalar", startMark, reader_.mark, "1-9", '0'));

            reader_.popFront();
            c = reader_.front;
            return true;
        }

        /// Scan (and ignore) ignored line in a block scalar.
        void scanBlockScalarIgnoredLine(const Mark startMark) @safe
        {
            findNextNonSpace();
            if(reader_.front == '#') { scanToNextBreak(); }

            enforce(reader_.front.among!(allBreaks), new UnexpectedTokenException("block scalar", startMark, reader_.mark, "comment or line break", reader_.front));

            scanLineBreak();
            return;
        }

        /// Scan indentation in a block scalar, returning line breaks, max indent and end mark.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        Tuple!(uint, Mark) scanBlockScalarIndentationToSlice() @system
        {
            uint maxIndent;
            Mark endMark = reader_.mark;

            while(reader_.front.among!(newLinesPlusSpaces))
            {
                if(reader_.front != ' ')
                {
                    reader_.sliceBuilder.write(scanLineBreak());
                    endMark = reader_.mark;
                    continue;
                }
                reader_.popFront();
                maxIndent = max(reader_.column, maxIndent);
            }

            return tuple(maxIndent, endMark);
        }

        /// Scan line breaks at lower or specified indentation in a block scalar.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        Mark scanBlockScalarBreaksToSlice(const uint indent) @trusted
        {
            Mark endMark = reader_.mark;

            for(;;)
            {
                while(reader_.column < indent && reader_.front == ' ') { reader_.popFront(); }
                if(!reader_.front.among!(newLines))  { break; }
                reader_.sliceBuilder.write(scanLineBreak());
                endMark = reader_.mark;
            }

            return endMark;
        }

        /// Scan a qouted flow scalar token with specified quotes.
        Token scanFlowScalar(const ScalarStyle quotes) @trusted
        {
            const startMark = reader_.mark;
            const quote     = reader_.front;
            reader_.popFront();

            reader_.sliceBuilder.begin();

            scanFlowScalarNonSpacesToSlice(quotes, startMark);

            while(reader_.front != quote)
            {
                scanFlowScalarSpacesToSlice(startMark);
                scanFlowScalarNonSpacesToSlice(quotes, startMark);
            }
            reader_.popFront();

            auto slice = reader_.sliceBuilder.finish();
            return scalarToken(startMark, reader_.mark, slice, quotes);
        }

        /// Scan nonspace characters in a flow scalar.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanFlowScalarNonSpacesToSlice(const ScalarStyle quotes, const Mark startMark)
            @system
        {
            for(;;) with(ScalarStyle)
            {
                dchar c = reader_.front;

                size_t numCodePoints = 0;
                while(!reader_.save().drop(numCodePoints).front.among!(allWhiteSpacePlusQuotesAndSlashes)) { ++numCodePoints; }

                reader_.sliceBuilder.write(reader_.take(numCodePoints).array);

                c = reader_.front;
                if(quotes == SingleQuoted && c == '\'' && reader_.save().drop(1).front == '\'')
                {
                    reader_.popFrontN(2);
                    reader_.sliceBuilder.write('\'');
                }
                else if((quotes == DoubleQuoted && c == '\'') ||
                        (quotes == SingleQuoted && c.among!('"', '\\')))
                {
                    reader_.popFront();
                    reader_.sliceBuilder.write(c);
                }
                else if(quotes == DoubleQuoted && c == '\\')
                {
                    reader_.popFront();
                    c = reader_.front;
                    if(c.among!(dyaml.escapes.escapeSeqs))
                    {
                        reader_.popFront();
                        // Escaping has been moved to Parser as it can't be done in
                        // place (in a slice) in case of '\P' and '\L' (very uncommon,
                        // but we don't want to break the spec)
                        char[2] escapeSequence = ['\\', cast(char)c];
                        reader_.sliceBuilder.write(escapeSequence);
                    }
                    else if(c.among!(dyaml.escapes.escapeHexSeq))
                    {
                        const hexLength = dyaml.escapes.escapeHexLength(c);
                        reader_.popFront();

                        foreach(i; 0 .. hexLength)
                            enforce(reader_.save().drop(i).front.isHexDigit, new UnexpectedTokenException("double quoted scalar", startMark, reader_.mark, "escape sequence of hexadecimal numbers", reader_.save().drop(i).front));
                        dchar[] hex = reader_.take(hexLength).array;
                        char[2] escapeStart = ['\\', cast(char) c];
                        reader_.sliceBuilder.write(escapeStart);
                        reader_.sliceBuilder.write(hex);
                        bool overflow;
                        // Note: This is just error checking; Parser does the actual
                        //       escaping (otherwise we could accidentally create an
                        //       escape sequence here that wasn't in input, breaking the
                        //       escaping code in parser, which is in parser because it
                        //       can't always be done in place)
                        parseNoGC!int(hex, 16u, overflow);
                        enforce(!overflow, new UnexpectedTokenException("double quoted scalar", startMark, reader_.mark, "hexadecimal value <= 0xFFFF", '\0'));
                    }
                    else if(c.among!(newLines))
                    {
                        scanLineBreak();
                        scanFlowScalarBreaksToSlice(startMark);
                    }
                    else
                    {
                        enforce(false, new UnexpectedTokenException("double quoted scalar", startMark, reader_.mark, "valid escape character", c));
                    }
                }
                else { return; }
            }
        }

        /// Scan space characters in a flow scalar.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// spaces into that slice.
        void scanFlowScalarSpacesToSlice(const Mark startMark) @system
        {
            // Increase length as long as we see whitespace.
            char[] whitespaces;
            while(reader_.front.among!(whiteSpaces)) {
                whitespaces ~= reader_.front;
                reader_.popFront();
            }

            // Can check the last byte without striding because '\0' is ASCII
            const c = reader_.front;
            enforce(c != '\0', new UnexpectedTokenException("quoted scalar", startMark, reader_.mark, "null", c));

            // Spaces not followed by a line break.
            if(!c.among!(newLines))
            {
                reader_.sliceBuilder.write(whitespaces);
                return;
            }

            // There's a line break after the spaces.
            const lineBreak = scanLineBreak();

            if(lineBreak != '\n') { reader_.sliceBuilder.write(lineBreak); }

            // If we have extra line breaks after the first, scan them into the
            // slice.
            const bool extraBreaks = scanFlowScalarBreaksToSlice(startMark);

            // No extra breaks, one normal line break. Replace it with a space.
            if(lineBreak == '\n' && !extraBreaks) { reader_.sliceBuilder.write(' '); }
        }

        /// Scan line breaks in a flow scalar.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// line breaks into that slice.
        bool scanFlowScalarBreaksToSlice(const Mark startMark) @system
        {
            // True if at least one line break was found.
            bool anyBreaks;
            for(;;)
            {
                // Instead of checking indentation, we check for document separators.
                enforce(!reader_.save().startsWith("---", "...") ||
                   !reader_.save().drop(3).front.among!(allWhiteSpace), new UnexpectedSequenceException("quoted scalar", startMark, reader_.mark, "document separator"));

                // Skip any whitespaces.
                while(reader_.front.among!(whiteSpaces)) { reader_.popFront(); }

                // Encountered a non-whitespace non-linebreak character, so we're done.
                if (!reader_.front.among!(newLines)) break;

                const lineBreak = scanLineBreak();
                anyBreaks = true;
                reader_.sliceBuilder.write(lineBreak);
            }
            return anyBreaks;
        }

        /// Scan plain scalar token (no block, no quotes).
        Token scanPlain() @trusted
        {
            // We keep track of the allowSimpleKey_ flag here.
            // Indentation rules are loosed for the flow context
            const startMark = reader_.mark;
            Mark endMark = startMark;
            const indent = indent_ + 1;

            // We allow zero indentation for scalars, but then we need to check for
            // document separators at the beginning of the line.
            // if(indent == 0) { indent = 1; }

            reader_.sliceBuilder.begin();

            alias Transaction = SliceBuilder.Transaction;
            Transaction spacesTransaction;
            // Stop at a comment.
            while(reader_.front != '#')
            {
                // Scan the entire plain scalar.
                size_t length = 0;
                dchar c = void;
                // Moved the if() out of the loop for optimization.
                if(flowLevel_ == 0)
                {
                    c = reader_.save().drop(length).front;
                    for(;;)
                    {
                        const cNext = reader_.save().drop(length+1).front;
                        if(c.among!(allWhiteSpace) ||
                           (c == ':' && cNext.among!(allWhiteSpace)))
                        {
                            break;
                        }
                        ++length;
                        c = cNext;
                    }
                }
                else
                {
                    for(;;)
                    {
                        c = reader_.save().drop(length).front;
                        if(c.among!(allWhiteSpace, ',', ':', '?', squareBrackets, curlyBraces))
                        {
                            break;
                        }
                        ++length;
                    }
                }

                // It's not clear what we should do with ':' in the flow context.
                if(flowLevel_ > 0 && c == ':' &&
                   !reader_.save().drop(length + 1).front.among!(allWhiteSpace, ',', squareBrackets, curlyBraces))
                {
                    // This is an error; throw the slice away.
                    spacesTransaction.commit();
                    reader_.sliceBuilder.finish();
                    reader_.popFrontN(length);
                    throw new UnexpectedSequenceException("plain scalar", startMark, reader_.mark, ":");
                }

                if(length == 0) { break; }

                allowSimpleKey_ = false;

                reader_.sliceBuilder.write(reader_.take(length).array);

                endMark = reader_.mark;

                spacesTransaction.commit();
                spacesTransaction = Transaction(reader_.sliceBuilder);

                const startLength = reader_.sliceBuilder.length;
                scanPlainSpacesToSlice(startMark);
                if(startLength == reader_.sliceBuilder.length ||
                   (flowLevel_ == 0 && reader_.column < indent))
                {
                    break;
                }
            }

            spacesTransaction.__dtor();
            char[] slice = reader_.sliceBuilder.finish();

            return scalarToken(startMark, endMark, slice, ScalarStyle.Plain);
        }

        /// Scan spaces in a plain scalar.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the spaces
        /// into that slice.
        void scanPlainSpacesToSlice(const Mark startMark) @system
        {
            // The specification is really confusing about tabs in plain scalars.
            // We just forbid them completely. Do not use tabs in YAML!

            // Get as many plain spaces as there are.
            char[] whitespaces;
            while(reader_.front == ' ') {
                whitespaces ~= reader_.front;
                reader_.popFront();
            }

            dchar c = reader_.front;
            // No newline after the spaces (if any)
            if(!c.among!(newLines))
            {
                // We have spaces, but no newline.
                if(whitespaces.length > 0) { reader_.sliceBuilder.write(whitespaces); }
                return;
            }

            // Newline after the spaces (if any)
            const lineBreak = scanLineBreak();
            allowSimpleKey_ = true;

            static bool end(Reader reader_)
            {
                return reader_.save().startsWith("---", "...")
                        && reader_.save().drop(3).front.among!(allWhiteSpace);
            }

            if(end(reader_)) { return; }

            bool extraBreaks = false;

            alias Transaction = SliceBuilder.Transaction;
            auto transaction = Transaction(reader_.sliceBuilder);
            if(lineBreak != '\n') { reader_.sliceBuilder.write(lineBreak); }
            while(reader_.front.among!(newLinesPlusSpaces))
            {
                if(reader_.front == ' ') { reader_.popFront(); }
                else
                {
                    const lBreak = scanLineBreak();
                    extraBreaks  = true;
                    reader_.sliceBuilder.write(lBreak);

                    if(end(reader_)) { return; }
                }
            }
            transaction.commit();

            // No line breaks, only a space.
            if(lineBreak == '\n' && !extraBreaks) { reader_.sliceBuilder.write(' '); }
        }

        /// Scan handle of a tag token.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanTagHandleToSlice(string name)(const Mark startMark) @system
        {
            dchar c = reader_.front;
            enforce(c == '!', new UnexpectedTokenException(name, startMark, reader_.mark, "'!'", c));

            uint length = 1;
            c = reader_.save().drop(length).front;
            if(c != ' ')
            {
                while(c.isAlphaNum || c.among!('-', '_'))
                {
                    ++length;
                    c = reader_.save().drop(length).front;
                }
                enforce(c == '!', new UnexpectedTokenException(name, startMark, reader_.mark, "'!'", c));
                ++length;
            }

            reader_.sliceBuilder.write(reader_.take(length).array);
        }

        /// Scan URI in a tag token.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanTagURIToSlice(string name)(const Mark startMark) @trusted
        {
            // Note: we do not check if URI is well-formed.
            dchar c = reader_.front;
            const startLen = reader_.sliceBuilder.length;
            {
                uint length = 0;
                while(c.isAlphaNum || c.among!('-', ';', '/', '?', ':', '&', '@', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', parentheses, squareBrackets, '%'))
                {
                    if(c == '%')
                    {
                        auto chars = reader_.take(length).array;
                        reader_.sliceBuilder.write(chars);
                        length = 0;
                        scanURIEscapesToSlice!name(startMark);
                    }
                    else { ++length; }
                    c = reader_.save().drop(length).front;
                }
                if(length > 0)
                {
                    auto chars = reader_.take(length).array;
                    reader_.sliceBuilder.write(chars);
                    length = 0;
                }
            }
            // OK if we scanned something, error otherwise.
            enforce(reader_.sliceBuilder.length > startLen, new UnexpectedTokenException(name, startMark, reader_.mark, "URI", c));
        }

        // Not @nogc yet because std.utf.decode is not @nogc
        /// Scan URI escape sequences.
        ///
        /// Assumes that the caller is building a slice in Reader, and puts the scanned
        /// characters into that slice.
        void scanURIEscapesToSlice(string name)(const Mark startMark) @system
        {
            // URI escapes encode a UTF-8 string. We store UTF-8 code units here for
            // decoding into UTF-32.
            char[4] bytes;
            size_t bytesUsed;
            Mark mark = reader_.mark;

            // Get one dchar by decoding data from bytes.
            //
            // This is probably slow, but simple and URI escapes are extremely uncommon
            // in YAML.
            //
            // Returns the number of bytes used by the dchar in bytes on success,
            // size_t.max on failure.
            static size_t getDchar(char[] bytes, Reader reader_)
            {
                size_t nextChar;
                dchar c;
                if(bytes[0] < 0x80)
                {
                    c = bytes[0];
                    ++nextChar;
                }
                reader_.sliceBuilder.write(c);
                if(bytes.length - nextChar > 0)
                {
                    core.stdc.string.memmove(bytes.ptr, bytes.ptr + nextChar,
                                             bytes.length - nextChar);
                }
                return bytes.length - nextChar;
            }

            enum contextMsg = "While scanning a " ~ name;
            while(reader_.front == '%')
            {
                reader_.popFront();
                if(bytesUsed == bytes.length)
                {
                    bytesUsed = getDchar(bytes[], reader_);
                    enforce(bytesUsed != size_t.max,  new UnexpectedSequenceException(name, startMark, reader_.mark, "Invalid UTF-8 in URI"));
                }

                char b = 0;
                uint mult = 16;
                // Converting 2 hexadecimal digits to a byte.
                foreach(k; 0 .. 2)
                {
                    const dchar c = reader_.save().drop(k).front;
                    enforce(c.isHexDigit, new UnexpectedTokenException(name, startMark, reader_.mark, "URI escape sequence with two hexadecimal numbers", c));

                    uint digit;
                    if(c - '0' < 10)     { digit = c - '0'; }
                    else if(c - 'A' < 6) { digit = c - 'A'; }
                    else if(c - 'a' < 6) { digit = c - 'a'; }
                    else                 { assert(false); }
                    b += mult * digit;
                    mult /= 16;
                }
                bytes[bytesUsed++] = b;

                reader_.popFrontN(2);
            }

            bytesUsed = getDchar(bytes[0 .. bytesUsed], reader_);
        }


        /// Scan a line break, if any.
        ///
        /// Transforms:
        ///   '\r\n'      :   '\n'
        ///   '\r'        :   '\n'
        ///   '\n'        :   '\n'
        ///   '\u0085'    :   '\n'
        ///   '\u2028'    :   '\u2028'
        ///   '\u2029     :   '\u2029'
        ///   no break    :   '\0'
        dchar scanLineBreak() @safe
        {
            // Fast path for ASCII line breaks.
            const b = reader_.front;
            if(b < 0x80)
            {
                if(b == '\n' || b == '\r')
                {
                    if(reader_.save().startsWith("\r\n")) { reader_.popFrontN(2); }
                    else { reader_.popFront(); }
                    return '\n';
                }
                return '\0';
            }

            const c = reader_.front;
            if(c == '\x85')
            {
                reader_.popFront();
                return '\n';
            }
            if(c == '\u2028' || c == '\u2029')
            {
                reader_.popFront();
                return c;
            }
            return '\0';
            //switch(reader_.save().startsWith("\r\n", "\r", "\n", "\u0085", "\u2028"d, "\u2029"d)) {
            //    default: return '\0';
            //    case 1: reader_.popFrontN(2); return '\n';
            //    case 2,3,4: reader_.popFront(); return '\n';
            //    case 5: reader_.popFront(); return '\u2028';
            //    case 6: reader_.popFront(); return '\u2029';
            //}
        }
}

private:

/// A nothrow function that converts a dchar[] to a string.
string utf32To8(C)(C[] str) @safe pure nothrow
    if(is(Unqual!C == dchar))
{
    try                    { return str.to!string; }
    catch(ConvException e) { assert(false, "Unexpected invalid UTF-32 string"); }
    catch(Exception e)     { assert(false, "Unexpected exception during UTF-8 encoding"); }
}

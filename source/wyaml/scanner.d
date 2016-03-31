
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// YAML scanner.
/// Code based on PyYAML: http://www.pyyaml.org
module wyaml.scanner;


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
import std.utf;

import wyaml.escapes;
import wyaml.exception;
import wyaml.queue;
import wyaml.reader;
import wyaml.style;
import wyaml.token;

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
alias miscValidURIChars = AliasSeq!('-', ';', '/', '?', ':', '&', '@', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', parentheses, squareBrackets, '%');

/// Marked exception thrown at scanner errors.
///
/// See_Also: MarkedYAMLException
class ScannerException : MarkedYAMLException
{
    mixin MarkedExceptionCtors;
}
class UnexpectedTokenException : YAMLException {
    this(string context, string expected, dchar got, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super("Expected %s in %s, got %s".format(expected, context, got), file, line);
    }
}
class UnexpectedSequenceException : YAMLException {
    this(string context, string unexpected, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super("Found unexpected %s in %s".format(unexpected, context), file, line);
    }
}
class UnexpectedSequenceWithMarkException : YAMLException {
    this(UnexpectedSequenceException e, in Mark begin, in Mark end) @safe pure {
        super(""~e.msg, e.file, e.line);
    }
}
class UnexpectedTokenWithMarkException : YAMLException {
    this(UnexpectedTokenException e, in Mark begin, in Mark end) @safe pure {
        super(""~e.msg, e.file, e.line);
    }
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
            auto startMark = reader_.mark;
            try {
                // Eat whitespaces and comments until we reach the next token.
                scanToNextToken();

                // Remove obsolete possible simple keys.
                stalePossibleSimpleKeys();

                // Compare current indentation and column. It may add some tokens
                // and decrease the current indentation level.
                unwindIndent(reader_.column);

                // Get the next character.

                // Fetch the token.
                if(reader_.empty)        { return fetchStreamEnd();     }
                const dchar c = reader_.front;
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
            } catch (UnexpectedTokenException e) {
                throw new UnexpectedTokenWithMarkException(e, startMark, reader_.mark);
            } catch (UnexpectedSequenceException e) {
                throw new UnexpectedSequenceWithMarkException(e, startMark, reader_.mark);
            }

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
            if (readerCopy.empty)
                return true;
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
                findNextNonSpace(reader_);
                if (reader_.empty) break;
                if(reader_.front == '#') { scanToNextBreak(reader_); }
                if(scanLineBreak(reader_) != '\0')
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
            const name = scanDirectiveName(reader_);

            // Index where tag handle ends and suffix starts in a tag directive value.
            uint tagHandleEnd = uint.max;
            dchar[] value;
            if(name == "YAML")     { value = scanYAMLDirectiveValue(reader_); }
            else if(name == "TAG") { value = scanTagDirectiveValue(reader_, tagHandleEnd); }

            Mark endMark = reader_.mark;

            DirectiveType directive;
            if(name == "YAML")     { directive = DirectiveType.YAML; }
            else if(name == "TAG") { directive = DirectiveType.TAG; }
            else
            {
                directive = DirectiveType.Reserved;
                scanToNextBreak(reader_);
            }

            scanDirectiveIgnoredLine(reader_);
            return directiveToken(startMark, endMark, value.toUTF8.dup, directive, tagHandleEnd);
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

            char[] value;
            if(i == '*') { value = scanAlphaNumeric(reader_, "an alias").toUTF8.dup; }
            else         { value = scanAlphaNumeric(reader_, "an anchor").toUTF8.dup; }


            enforce(reader_.front.among!(allWhiteSpace, '?', ':', ',', ']', '}', '%', '@'), new UnexpectedTokenException(i == '*' ? "alias" : "anchor", "alphanumeric, '-' or '_'", reader_.front));
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
            dchar[] slice;
            uint handleEnd;

            if(c == '<')
            {
                reader_.popFrontN(2);

                handleEnd = 0;
                slice ~= scanTagURI(reader_, "tag");
                enforce(reader_.front == '>', new UnexpectedTokenException("tag", "'>'", reader_.front));
                reader_.popFront();
            }
            else if(c.among!(allWhiteSpace))
            {
                reader_.popFront();
                handleEnd = 0;
                slice ~= '!';
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
                    slice ~= scanTagHandle(reader_, "tag");
                    handleEnd = cast(uint)slice.length;
                }
                else
                {
                    reader_.popFront();
                    slice ~= '!';
                    handleEnd = cast(uint)slice.length;
                }

                slice ~= scanTagURI(reader_, "tag");
            }

            enforce(reader_.front.among!(allWhiteSpace), new UnexpectedTokenException("tag", "' '", reader_.front));

            return tagToken(startMark, reader_.mark, slice.toUTF8.dup, handleEnd);
        }

        /// Scan a block scalar token with specified style.
        Token scanBlockScalar(const ScalarStyle style) @trusted
        {
            const startMark = reader_.mark;
            // Scan the header.
            reader_.popFront();

            const indicators = scanBlockScalarIndicators(reader_);

            const chomping   = indicators[0];
            const increment  = indicators[1];
            scanBlockScalarIgnoredLine(reader_);

            // Determine the indentation level and go to the first non-empty line.
            Mark endMark;
            uint indent = max(1, indent_ + 1);

            dchar[] slice;
            dchar[] newSlice;
            // Read the first indentation/line breaks before the scalar.
            size_t startLen = 0;
            if(increment == int.min)
            {
                uint indentation;
                newSlice ~= scanBlockScalarIndentation(reader_, indentation, endMark);
                indent  = max(indent, indentation);
            }
            else
            {
                indent += increment - 1;
                newSlice ~= scanBlockScalarBreaks(reader_, indent, endMark);
            }

            dchar lineBreak = '\0';
            size_t fullLen = 0;
            // Scan the inner part of the block scalar.
            while(reader_.column == indent && !reader_.empty)
            {
                slice ~= newSlice;
                newSlice = [];
                const bool leadingNonSpace = !reader_.front.among!(whiteSpaces);
                // This is where the 'interesting' non-whitespace data gets read.
                slice ~= scanToNextBreak(reader_);
                lineBreak = scanLineBreak(reader_);

                fullLen = slice.length+newSlice.length;
                startLen = 0;
                // The line breaks should actually be written _after_ the if() block
                // below. We work around that by inserting
                newSlice ~= scanBlockScalarBreaks(reader_, indent, endMark);

                // This will not run during the last iteration (see the if() vs the
                // while()), hence breaksTransaction rollback (which happens after this
                // loop) will never roll back data written in this if() block.
                if(reader_.column == indent && !reader_.empty)
                {
                    // Unfortunately, folding rules are ambiguous.

                    // This is the folding according to the specification:
                    if(style == ScalarStyle.Folded && lineBreak == '\n' &&
                       leadingNonSpace && !reader_.front.among!(whiteSpaces))
                    {
                        if(startLen == newSlice.length)
                        {
                            newSlice ~= ' ';
                        }
                    }
                    else
                    {
                        newSlice = chain(newSlice[0..startLen], [lineBreak], newSlice[startLen..$]).array;
                    }
                }
                else
                {
                    break;
                }
            }

            // If chompint is Keep, we keep (commit) the last scanned line breaks
            // (which are at the end of the scalar). Otherwise re remove them (end the
            // transaction).
            if(chomping == Chomping.Keep)  { slice ~= newSlice; }
            if(chomping != Chomping.Strip && lineBreak != '\0')
            {
                // If chomping is Keep, we keep the line break but the first line break
                // that isn't stripped (since chomping isn't Strip in this branch) must
                // be inserted _before_ the other line breaks.
                if(chomping == Chomping.Keep)
                {
                    slice = chain(slice[0..fullLen], [lineBreak], slice[fullLen..$]).array;
                }
                // If chomping is not Keep, breaksTransaction was cancelled so we can
                // directly write the first line break (as it isn't stripped - chomping
                // is not Strip)
                else
                {
                    slice ~= lineBreak;
                }
            }

            return scalarToken(startMark, endMark, slice.toUTF8.dup, style);
        }


        /// Scan a quoted flow scalar token with specified quotes.
        Token scanFlowScalar(const ScalarStyle quotes) @trusted
        {
            const startMark = reader_.mark;
            const quote     = reader_.front;
            reader_.popFront();

            dchar[] slice = scanFlowScalarNonSpaces(reader_, quotes);

            while(!reader_.empty && reader_.front != quote)
            {
                slice ~= scanFlowScalarSpaces(reader_);
                slice ~= scanFlowScalarNonSpaces(reader_, quotes);
            }
            enforce (!reader_.empty, new UnexpectedSequenceException("quoted flow scalar", "EOF"));
            reader_.popFront();

            return scalarToken(startMark, reader_.mark, slice.toUTF8.dup, quotes);
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

            dchar[] slice;
            dchar[] newSlice;
            // Stop at a comment.
            while(!reader_.empty && reader_.front != '#')
            {
                // Scan the entire plain scalar.
                size_t length = 0;
                dchar c = void;
                // Moved the if() out of the loop for optimization.
                if(flowLevel_ == 0)
                {
                    auto savedReader = reader_.save();
                    c = savedReader.front;
                    for(;;)
                    {
                        if (savedReader.empty)
                            break;
                        savedReader.popFront();
                        const cNext = savedReader.front;
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
                    throw new UnexpectedSequenceException("plain scalar", ":");
                }

                if(length == 0) { break; }

                allowSimpleKey_ = false;

                newSlice ~= reader_.take(length).array;

                endMark = reader_.mark;

                slice ~= newSlice;
                newSlice = [];

                const startLength = slice.length;
                newSlice ~= scanPlainSpaces(reader_, allowSimpleKey_);
                if(startLength == newSlice.length+slice.length ||
                   (flowLevel_ == 0 && reader_.column < indent))
                {
                    break;
                }
            }

            return scalarToken(startMark, endMark, slice.toUTF8.dup, ScalarStyle.Plain);
        }
}
/// Move to the next non-space character.
void findNextNonSpace(T)(ref T reader) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    reader.until!(x => x != ' ').walkLength;
}

/// Scan a string of alphanumeric or "-_" characters.
auto scanAlphaNumeric(T)(ref T reader, string name) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    auto output = reader.until!(x => !(x.isAlphaNum || x.among!('-', '_'))).array;
    enforce(!output.empty, new UnexpectedTokenException(name, "alphanumeric, '-', or '_'", reader.front));
    return output;
}

/// Scan all characters until next line break.
auto scanToNextBreak(T)(ref T reader) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    return reader.until!(x => x.among!allBreaks).array;
}
/// Scan name of a directive token.
auto scanDirectiveName(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    // Scan directive name.
    auto output = scanAlphaNumeric(reader, "a directive");
    enforce(reader.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", "alphanumeric, '-' or '_'", reader.front));
    return output;
}

/// Scan value of a YAML directive token. Returns major, minor version separated by '.'.
auto scanYAMLDirectiveValue(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    dchar[] output;
    findNextNonSpace(reader);

    output ~= scanYAMLDirectiveNumber(reader);

    enforce(reader.front == '.', new UnexpectedTokenException("directive", "digit or '.'", reader.front));
    // Skip the '.'.
    reader.popFront();

    output ~= '.';
    output ~= scanYAMLDirectiveNumber(reader);

    enforce(reader.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", "digit or '.'", reader.front));
    return output;
}

/// Scan a number from a YAML directive.
auto scanYAMLDirectiveNumber(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    enforce(reader.front.isDigit, new UnexpectedTokenException("directive", "digit", reader.front));
    return reader.until!(x => x.isDigit)(OpenRight.no).array;
}

/// Scan value of a tag directive.
///
/// Returns: Length of tag handle (which is before tag prefix) in scanned data
auto scanTagDirectiveValue(T)(ref T reader, out uint handleLength) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    dchar[] output;
    findNextNonSpace(reader);
    output ~= scanTagDirectiveHandle(reader);
    handleLength = cast(uint)(output.length);
    findNextNonSpace(reader);
    output ~= scanTagDirectivePrefix(reader);

    return output;
}

/// Scan handle of a tag directive.
auto scanTagDirectiveHandle(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    auto output = scanTagHandle(reader, "directive");
    enforce(reader.front == ' ', new UnexpectedTokenException("directive", "' '", reader.front));
    return output;
}

/// Scan prefix of a tag directive.
auto scanTagDirectivePrefix(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    auto output = scanTagURI(reader, "directive");
    enforce(reader.front.among!(allWhiteSpace), new UnexpectedTokenException("directive", "' '", reader.front));
    return output;
}

/// Scan (and ignore) ignored line after a directive.
void scanDirectiveIgnoredLine(T)(ref T reader) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    findNextNonSpace(reader);
    if(reader.front == '#') { scanToNextBreak(reader); }
    enforce(reader.front.among!(allBreaks), new UnexpectedTokenException("directive", "comment or a line break", reader.front));
    scanLineBreak(reader);
}
/// Scan chomping and indentation indicators of a scalar token.
Tuple!(Chomping, int) scanBlockScalarIndicators(T)(ref T reader) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    auto chomping = Chomping.Clip;
    int increment = int.min;
    dchar c       = reader.front;

    /// Indicators can be in any order.
    if(getChomping(reader, c, chomping))
    {
        getIncrement(reader, c, increment);
    }
    else
    {
        const gotIncrement = getIncrement(reader, c, increment);
        if(gotIncrement) { getChomping(reader, c, chomping); }
    }

    enforce(c.among!(allWhiteSpace), new UnexpectedTokenException("block scalar", "chomping or indentation indicator", c));

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
bool getChomping(T)(ref T reader, ref dchar c, ref Chomping chomping) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    if(!c.among!(chompIndicators)) { return false; }
    chomping = c == '+' ? Chomping.Keep : Chomping.Strip;
    reader.popFront();
    c = reader.front;
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
bool getIncrement(T)(ref T reader, ref dchar c, ref int increment) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    if(!c.isDigit) { return false; }
    // Convert a digit to integer.
    increment = c - '0';
    assert(increment < 10 && increment >= 0, "Digit has invalid value");
    enforce(increment > 0, new UnexpectedTokenException("block scalar", "1-9", '0'));

    reader.popFront();
    c = reader.front;
    return true;
}

/// Scan (and ignore) ignored line in a block scalar.
void scanBlockScalarIgnoredLine(T)(ref T reader) @safe if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    findNextNonSpace(reader);
    if(reader.front == '#') { scanToNextBreak(reader); }

    enforce(reader.front.among!(allBreaks), new UnexpectedTokenException("block scalar", "comment or line break", reader.front));

    scanLineBreak(reader);
    return;
}

/// Scan indentation in a block scalar, returning line breaks, max indent and end mark.
auto scanBlockScalarIndentation(T)(ref T reader, out uint maxIndent, out Mark endMark) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    dchar[] output;
    while(!reader.empty && reader.front.among!(newLinesPlusSpaces))
    {
        if(reader.front != ' ')
        {
            output ~= scanLineBreak(reader);
            endMark = reader.mark;
            continue;
        }
        reader.popFront();
        maxIndent = max(reader.column, maxIndent);
    }

    return output;
}

/// Scan line breaks at lower or specified indentation in a block scalar.
auto scanBlockScalarBreaks(T)(ref T reader, const uint indent, out Mark end) @trusted if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    end = reader.mark;
    dchar[] output;

    while(!reader.empty)
    {
        while(!reader.empty && reader.column < indent && reader.front == ' ') { reader.popFront(); }
        if(!reader.front.among!(newLines))  { break; }
        output ~= scanLineBreak(reader);
        end = reader.mark;
    }

    return output;
}
/// Scan nonspace characters in a flow scalar.
auto scanFlowScalarNonSpaces(T)(ref T reader, const ScalarStyle quotes) if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
    //@safe
{
    dchar[] output;
    for(;;) with(ScalarStyle)
    {
        dchar c = void;

        output ~= reader.until!(x => x.among!(allWhiteSpacePlusQuotesAndSlashes)).array;
        if (reader.empty)
            break;
        c = reader.front;
        if(quotes == SingleQuoted && c == '\'' && !reader.save().drop(1).empty && reader.save().drop(1).front == '\'')
        {
            reader.popFrontN(2);
            output ~= '\'';
        }
        else if((quotes == DoubleQuoted && c == '\'') ||
                (quotes == SingleQuoted && c.among!('"', '\\')))
        {
            reader.popFront();
            output ~= c;
        }
        else if(quotes == DoubleQuoted && c == '\\')
        {
            reader.popFront();
            c = reader.front;
            if(c.among!(wyaml.escapes.escapeSeqs))
            {
                reader.popFront();
                output ~= ['\\', c];
            }
            else if(c.among!(wyaml.escapes.escapeHexSeq))
            {
                const hexLength = wyaml.escapes.escapeHexLength(c);
                reader.popFront();

                auto v = reader.take(hexLength);
                auto hex = v.save().array;
                enforce(v.all!isHexDigit, new UnexpectedTokenException("double quoted scalar", "escape sequence of hexadecimal numbers", v.until!(x => x.isHexDigit).front));

                output ~= '\\';
                output ~= c;
                output ~= hex;
                parse!int(hex, 16u);
            }
            else if(c.among!(newLines))
            {
                scanLineBreak(reader);
                output ~= scanFlowScalarBreaks(reader);
            }
            else
            {
                throw new UnexpectedTokenException("double quoted scalar", "valid escape character", c);
            }
        }
        else
            break;
    }
    return output;
}
/// Scan space characters in a flow scalar.
auto scanFlowScalarSpaces(T)(ref T reader) @system if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar))
{
    dchar[] output;
    // Increase length as long as we see whitespace.
    dchar[] whitespaces;
    while(reader.front.among!(whiteSpaces)) {
        whitespaces ~= reader.front;
        reader.popFront();
    }

    enforce(!reader.empty, new UnexpectedSequenceException("quoted scalar", "end of stream"));
    const c = reader.front;

    // Spaces not followed by a line break.
    if(!c.among!(newLines))
    {
        output ~= whitespaces;
        return output;
    }

    // There's a line break after the spaces.
    const lineBreak = scanLineBreak(reader);

    if(lineBreak != '\n') { output ~= lineBreak; }

    bool extraBreaks;
    output ~= scanFlowScalarBreaks(reader, extraBreaks);

    // No extra breaks, one normal line break. Replace it with a space.
    if(lineBreak == '\n' && !extraBreaks) { output ~= ' '; }

    return output;
}
/// Scan line breaks in a flow scalar.
dchar[] scanFlowScalarBreaks(T)(ref T reader) if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar)) {
    bool waste;
    return scanFlowScalarBreaks(reader, waste);
}
auto scanFlowScalarBreaks(T)(ref T reader, out bool extraBreaks) if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar)) {
    dchar[] output;
    for(;;)
    {
        // Instead of checking indentation, we check for document separators.
        enforce(!reader.end(), new UnexpectedSequenceException("quoted scalar", "document separator"));

        // Skip any whitespaces.
        reader.until!(x => !x.among!whiteSpaces).walkLength;

        // Encountered a non-whitespace non-linebreak character, so we're done.
        if (reader.empty || !reader.front.among!(newLines)) break;

        const lineBreak = scanLineBreak(reader);
        extraBreaks = true;
        output ~= lineBreak;
    }
    return output;
}
unittest {
    auto str = "     ";
    assert(str.scanFlowScalarBreaks() == "");

    str = " \n  ";
    assert(str.scanFlowScalarBreaks() == "");
}
bool end(T)(T reader) if (isForwardRange!T && is(Unqual!(ElementType!T) == dchar)) {
    return reader.save().startsWith("---", "...")
            && reader.save().drop(3).front.among!(allWhiteSpace);
}
unittest {
    assert("---\r\n".end);
    assert("...\n".end);
    assert(!"...a".end);
    //assert("---".end);
    //assert("".end);
}
/// Scan spaces in a plain scalar.
auto scanPlainSpaces(T)(ref T reader, ref bool allowSimpleKey_) @system if (isInputRange!T && is(Unqual!(ElementType!T) == dchar))
{
    dchar[] output;
    // The specification is really confusing about tabs in plain scalars.
    // We just forbid them completely. Do not use tabs in YAML!

    // Get as many plain spaces as there are.
    dchar[] whitespaces;
    while(reader.front == ' ') {
        whitespaces ~= reader.front;
        reader.popFront();
    }

    dchar c = reader.front;
    // No newline after the spaces (if any)
    if(!c.among!(newLines))
    {
        // We have spaces, but no newline.
        if(whitespaces.length > 0) { output ~= whitespaces; }
        return output;
    }

    // Newline after the spaces (if any)
    const lineBreak = scanLineBreak(reader);
    allowSimpleKey_ = true;


    if(reader.end) { return output; }

    bool extraBreaks = false;

    if(lineBreak != '\n') { output ~= lineBreak; }
    while(!reader.empty && reader.front.among!(newLinesPlusSpaces))
    {
        if(reader.front == ' ') { reader.popFront(); }
        else
        {
            const lBreak = scanLineBreak(reader);
            extraBreaks  = true;
            output ~= lBreak;

            if(reader.end) { return output; }
        }
    }

    // No line breaks, only a space.
    if(lineBreak == '\n' && !extraBreaks) { output ~= ' '; }
    return output;
}
/// Scan handle of a tag token.
auto scanTagHandle(T)(ref T reader, string name = "tag handle") @system
{
    dchar c = reader.front;
    enforce(c == '!', new UnexpectedTokenException(name, "'!'", c));

    uint length = 1;
    c = reader.save().drop(length).front;
    if(c != ' ')
    {
        while(c.isAlphaNum || c.among!('-', '_'))
        {
            ++length;
            c = reader.save().drop(length).front;
        }
        enforce(c == '!', new UnexpectedTokenException(name, "'!'", c));
        ++length;
    }

    return reader.take(length).array;

    //return chain(reader.take(1), reader.drop(1).until!(x => !(x.isAlphaNum || x.among!('-', '_')))).array;
}
unittest {
    auto str = "!!wordswords ";
    assert(str.scanTagHandle() == "!!");
    assert(str == "!!wordswords ");
}
/// Scan URI in a tag token.
auto scanTagURI(T)(ref T reader, string name = "URI") @trusted if (isInputRange!T && is(Unqual!(ElementType!T) == dchar))  {
    // Note: we do not check if URI is well-formed.
    dchar[] output;
    while(!reader.empty && (reader.front.isAlphaNum || reader.front.among!(miscValidURIChars))) {
        if(reader.front == '%')
            output ~= scanURIEscapes(reader, name);
        if (reader.empty)
            break;
        output ~= reader.front;
        reader.popFront();
    }
    // OK if we scanned something, error otherwise.
    enforce(output.length > 0, new UnexpectedTokenException(name, "URI", reader.front));
    return output;
}
unittest {
    auto str = "http://example.com";
    assert(str.scanTagURI() == "http://example.com");

    str = "http://example.com/%20";
    assert(str.scanTagURI() == "http://example.com/ ");
}
/// Scan URI escape sequences.
dchar[] scanURIEscapes(T)(ref T reader, string name = "URI escape") if (isInputRange!T && is(Unqual!(ElementType!T) == dchar)) {
    import std.uri : decodeComponent;
    dchar[] uriBuf;
    while(!reader.empty && reader.front == '%') {
        reader.popFront();
        uriBuf ~= '%';
        dchar[] nextTwo = reader.take(2).array;
        static if(isForwardRange!T)
            reader.popFrontN(2);
        if(!nextTwo.all!isHexDigit)
            throw new UnexpectedTokenException(name, "URI escape sequence with two hexadecimal numbers", nextTwo.until!(x => x.isHexDigit).front);
        uriBuf ~= nextTwo;
    }
    return decodeComponent(uriBuf).to!(dchar[]);
}
unittest {
    //it's a space!
    auto str = "%20";
    assert(str.scanURIEscapes() == " ");
    assert(str == "");

    //not an escape
    str = "2";
    assert(str.scanURIEscapes() == "");
    assert(str == "2");

    //empty
    str = "";
    assert(str.scanURIEscapes() == "");
    assert(str == "");

    //invalid escape
    str = "%H";
    assertThrown(str.scanURIEscapes());

    //2-byte char
    str = "%C3%A2";
    assert(str.scanURIEscapes() == "â");
    assert(str == "");

    //3-byte char
    str = "%E2%9C%A8";
    assert(str.scanURIEscapes() == "✨");
    assert(str == "");

    //4-byte char
    str = "%F0%9D%84%A0";
    assert(str.scanURIEscapes() == "𝄠");
    assert(str == "");

    //two 1-byte chars
    str = "%20%20";
    assert(str.scanURIEscapes() == "  ");
    assert(str == "");

    //ditto, but with non-escape char
    str = "%20%20s";
    assert(str.scanURIEscapes() == "  ");
    assert(str == "s");
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
dchar scanLineBreak(T)(ref T reader_) @safe if (isInputRange!T && is(Unqual!(ElementType!T) == dchar)) {
    // Fast path for ASCII line breaks.
    if (reader_.empty)
        return '\0';
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
unittest {
    string str = "\r\n";
    assert(str.scanLineBreak() == '\n');
    assert(str == "");
    str = "\r";
    assert(str.scanLineBreak() == '\n');
    assert(str == "");
    str = "\n";
    assert(str.scanLineBreak() == '\n');
    assert(str == "");
    str = "\u0085";
    assert(str.scanLineBreak() == '\n');
    assert(str == "");
    str = "\u2028";
    assert(str.scanLineBreak() == '\u2028');
    assert(str == "");
    str = "\u2029";
    assert(str.scanLineBreak() == '\u2029');
    assert(str == "");
    str = "";
    assert(str.scanLineBreak() == '\0');
    assert(str == "");
    str = "b";
    assert(str.scanLineBreak() == '\0');
    assert(str == "b");
    str = "\nb";
    assert(str.scanLineBreak() == '\n');
    assert(str == "b");
}
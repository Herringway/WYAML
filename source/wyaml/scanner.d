//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// YAML scanner.
/// Code based on PyYAML: http://www.pyyaml.org
module wyaml.scanner;

import std.algorithm;
import std.conv;
import std.ascii : isAlphaNum, isDigit, isHexDigit;
import std.exception;
import std.meta;
import std.range;
import std.string;
import std.typecons;
import std.traits : Unqual, isArray;
import std.utf;

import wyaml.escapes;
import wyaml.exception;
import wyaml.queue;
import wyaml.reader;
import wyaml.style;
import wyaml.token;

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

package alias newLines = AliasSeq!('\n', '\r', '\u0085', '\u2028', '\u2029');
package alias newLinesPlusSpaces = AliasSeq!(newLines, ' ');
package alias whiteSpaces = AliasSeq!(' ', '\t');
package alias allBreaks = AliasSeq!(newLines);
package alias allWhiteSpace = AliasSeq!(whiteSpaces, allBreaks);
package alias allWhiteSpacePlusQuotesAndSlashes = AliasSeq!(allWhiteSpace, '\'', '"', '\\');
package alias chompIndicators = AliasSeq!('+', '-');
package alias curlyBraces = AliasSeq!('{', '}');
package alias squareBrackets = AliasSeq!('[', ']');
package alias parentheses = AliasSeq!('(', ')');
package alias miscValidURIChars = AliasSeq!('-', ';', '/', '?', ':', '&', '@', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', parentheses, squareBrackets, '%');

package enum bool isYAMLStream(T) = isInputRange!T && is(Unqual!(ElementType!T) == dchar);
package enum bool isForwardYAMLStream(T) = isYAMLStream!T && isForwardRange!T;
package enum bool isMarkable(T) = isForwardYAMLStream!T && hasMember!(T, "mark");

package template worksWithYAMLStreams(alias func) {
	struct SimpleInputRange {
		dchar front;
		bool empty() {
			return true;
		}

		void popFront() {
		}
	}

	SimpleInputRange test;
	enum worksWithYAMLStreams = __traits(compiles, func(test));
}

package template worksWithForwardYAMLStreams(alias func) {
	struct SimpleInputRange {
		dchar front;
		bool empty() {
			return true;
		}

		void popFront() {
		}

		SimpleInputRange save() {
			return this;
		}
	}

	SimpleInputRange test;
	enum worksWithForwardYAMLStreams = __traits(compiles, func(test));
}

/// Marked exception thrown at scanner errors.
///
/// See_Also: MarkedYAMLException
package class ScannerException : MarkedYAMLException {
	mixin MarkedExceptionCtors;
}

package class UnexpectedTokenException : YAMLException {
	this(T)(string context, string expected, T range, string file = __FILE__, size_t line = __LINE__) if (isYAMLStream!T) {
		if (range.empty)
			super("Expected %s in %s, got end of range".format(expected, context), file, line);
		else
			super("Expected %s in %s, got %s".format(expected, context, range.front), file, line);
	}
}

package class UnexpectedSequenceException : YAMLException {
	this(string context, string unexpected, string file = __FILE__, size_t line = __LINE__) @safe pure {
		super("Found unexpected %s in %s".format(unexpected, context), file, line);
	}
}

package class UnexpectedSequenceWithMarkException : YAMLException {
	this(UnexpectedSequenceException e, in Mark begin, in Mark end) @safe pure {
		super("" ~ e.msg, e.file, e.line);
	}
}

package class UnexpectedTokenWithMarkException : YAMLException {
	this(UnexpectedTokenException e, in Mark begin, in Mark end) @safe pure {
		super("" ~ e.msg, e.file, e.line);
	}
}

/// Block chomping types.
package enum Chomping {
	/// Strip all trailing line breaks. '-' indicator.
	Strip,
	/// Line break of the last line is preserved, others discarded. Default.
	Clip,
	/// All trailing line breaks are preserved. '+' indicator.
	Keep
}
/// Generates tokens from data provided by a Reader.
package final class Scanner {
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
	private static struct SimpleKey {
		/// Index of the key token from start (first token scanned being 0).
		size_t tokenIndex;
		/// Line the key starts at.
		uint line;
		/// Column the key starts at.
		uint column;
		/// Is this required to be a simple key?
		bool required;
		/// Is this struct "null" (invalid)?.
		bool isNull;
	}

	/// Reader used to read from a file/stream.
	private Reader reader_;
	/// Are we done scanning?
	private bool done_;

	/// Level of nesting in flow context. If 0, we're in block context.
	private uint flowLevel_;
	/// Current indentation level.
	private int indent_ = -1;
	/// Past indentation levels. Used as a stack.
	private int[] indents_;

	/// Processed tokens not yet emitted. Used as a queue.
	private Queue!Token tokens_;

	/// Number of tokens emitted through the getToken method.
	private uint tokensTaken_;

	/// Can a simple key start at the current position? A simple key may start:
	/// - at the beginning of the line, not counting indentation spaces
	///       (in block context),
	/// - after '{', '[', ',' (in the flow context),
	/// - after '?', ':', '-' (in the block context).
	/// In the block context, this flag also signifies if a block collection
	/// may start at the current position.
	private bool allowSimpleKey_ = true;

	/// Possible simple keys indexed by flow levels.
	private SimpleKey[] possibleSimpleKeys_;

	/// Construct a Scanner using specified Reader.
	public this(Reader reader) @safe nothrow {
		// Return the next token, but do not delete it from the queue
		reader_ = reader;
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
	public bool checkToken(const TokenID[] ids...) {
		// Check if the next token is one of specified types.
		while (needMoreTokens()) {
			fetchToken();
		}
		if (!tokens_.empty) {
			if (ids.length == 0) {
				return true;
			} else {
				const nextId = tokens_.peek().id;
				foreach (id; ids) {
					if (nextId == id) {
						return true;
					}
				}
			}
		}
		return false;
	}

	/// Return the next token, but keep it in the queue.
	///
	/// Must not be called if there are no tokens left.
	public ref const(Token) peekToken() {
		while (needMoreTokens) {
			fetchToken();
		}
		if (!tokens_.empty) {
			return tokens_.peek();
		}
		assert(false, "No token left to peek");
	}

	/// Return the next token, removing it from the queue.
	///
	/// Must not be called if there are no tokens left.
	public Token getToken() {
		while (needMoreTokens) {
			fetchToken();
		}
		if (!tokens_.empty) {
			++tokensTaken_;
			return tokens_.pop();
		}
		assert(false, "No token left to get");
	}

	/// Determine whether or not we need to fetch more tokens before peeking/getting a token.
	private bool needMoreTokens() @safe pure {
		if (done_) {
			return false;
		}
		if (tokens_.empty) {
			return true;
		}

		/// The current token may be a potential simple key, so we need to look further.
		stalePossibleSimpleKeys();
		return nextPossibleSimpleKey() == tokensTaken_;
	}

	/// Fetch at token, adding it to tokens_.
	private void fetchToken() {
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
			if (reader_.empty) {
				return fetchStreamEnd();
			}
			const dchar c = reader_.front;
			if (checkDirective()) {
				return fetchDirective();
			}
			if (checkDocumentStart()) {
				return fetchDocumentStart();
			}
			if (checkDocumentEnd()) {
				return fetchDocumentEnd();
			}
			// Order of the following checks is NOT significant.
			switch (c) {
				case '[':
					tokens_.push(fetchFlowSequenceStart());
					return;
				case '{':
					tokens_.push(fetchFlowMappingStart());
					return;
				case ']':
					tokens_.push(fetchFlowSequenceEnd());
					return;
				case '}':
					tokens_.push(fetchFlowMappingEnd());
					return;
				case ',':
					tokens_.push(fetchFlowEntry());
					return;
				case '!':
					tokens_.push(fetchTag());
					return;
				case '\'':
					tokens_.push(fetchSingle());
					return;
				case '\"':
					tokens_.push(fetchDouble());
					return;
				case '*':
					tokens_.push(fetchAlias());
					return;
				case '&':
					tokens_.push(fetchAnchor());
					return;
				case '?':
					if (checkKey()) {
						return fetchKey();
					}
					goto default;
				case ':':
					if (checkValue()) {
						return fetchValue();
					}
					goto default;
				case '-':
					if (checkBlockEntry()) {
						return fetchBlockEntry();
					}
					goto default;
				case '|':
					if (flowLevel_ == 0) {
						return fetchLiteral();
					}
					break;
				case '>':
					if (flowLevel_ == 0) {
						return fetchFolded();
					}
					break;
				default:
					if (checkPlain()) {
						return fetchPlain();
					}
			}
			throw new ScannerException("While scanning for the next token, found character \'%s\', index %s that cannot start any token".format(c, to!int(c)), reader_.mark);
		}
		catch (UnexpectedTokenException e) {
			throw new UnexpectedTokenWithMarkException(e, startMark, reader_.mark);
		}
		catch (UnexpectedSequenceException e) {
			throw new UnexpectedSequenceWithMarkException(e, startMark, reader_.mark);
		}

	}

	/// Return the token number of the nearest possible simple key.
	private uint nextPossibleSimpleKey() @safe pure nothrow @nogc {
		uint minTokenNumber = uint.max;
		foreach (k, ref simpleKey; possibleSimpleKeys_) {
			if (simpleKey.isNull) {
				continue;
			}
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
	private void stalePossibleSimpleKeys() @safe pure {
		foreach (level, ref key; possibleSimpleKeys_) {
			if (key.isNull) {
				continue;
			}
			if (key.line != reader_.line) {
				enforce(!key.required, new ScannerException("While scanning a simple key", Mark(key.line, key.column), "could not find expected ':'", reader_.mark));
				key.isNull = true;
			}
		}
	}

	/// Check if the next token starts a possible simple key and if so, save its position.
	///
	/// This function is called for ALIAS, ANCHOR, TAG, SCALAR(flow), '[', and '{'.
	private void savePossibleSimpleKey() @safe pure {
		// Check if a simple key is required at the current position.
		const required = (flowLevel_ == 0 && indent_ == reader_.column);
		assert(allowSimpleKey_ || !required, "A simple key is required only if it is the first token in the current line. Therefore it is always allowed.");

		if (!allowSimpleKey_) {
			return;
		}

		// The next token might be a simple key, so save its number and position.
		removePossibleSimpleKey();
		const tokenCount = tokensTaken_ + tokens_.length;

		const key = SimpleKey(tokenCount, reader_.line, min(reader_.column, uint.max), required);

		if (possibleSimpleKeys_.length <= flowLevel_) {
			const oldLength = possibleSimpleKeys_.length;
			possibleSimpleKeys_.length = flowLevel_ + 1;
			//No need to initialize the last element, it's already done in the next line.
			possibleSimpleKeys_[oldLength .. flowLevel_] = SimpleKey.init;
		}
		possibleSimpleKeys_[flowLevel_] = key;
	}

	/// Remove the saved possible key position at the current flow level.
	private void removePossibleSimpleKey() @safe pure {
		if (possibleSimpleKeys_.length <= flowLevel_) {
			return;
		}

		if (!possibleSimpleKeys_[flowLevel_].isNull) {
			const key = possibleSimpleKeys_[flowLevel_];
			enforce(!key.required, new ScannerException("While scanning a simple key", Mark(key.line, key.column), "could not find expected ':'", reader_.mark));
			possibleSimpleKeys_[flowLevel_].isNull = true;
		}
	}

	/// Decrease indentation, removing entries in indents_.
	///
	/// Params:  column = Current column in the file/stream.
	private void unwindIndent(const int column) @safe {
		if (flowLevel_ > 0) {
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
		while (indent_ > column) {
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
	private bool addIndent(int column) @safe {
		if (indent_ >= column) {
			return false;
		}
		indents_ ~= indent_;
		indent_ = column;
		return true;
	}

	/// Add STREAM-START token.
	private void fetchStreamStart() @safe nothrow {
		tokens_.push(streamStartToken(reader_.mark, reader_.mark));
	}

	private void unwindAndReset() @safe {
		// Set intendation to -1 .
		unwindIndent(-1);
		// Reset simple keys.
		removePossibleSimpleKey();
		allowSimpleKey_ = false;
	}
	///Add STREAM-END token.
	private void fetchStreamEnd() @safe {
		unwindAndReset();

		tokens_.push(streamEndToken(reader_.mark, reader_.mark));
		done_ = true;
	}

	/// Add DIRECTIVE token.
	private void fetchDirective() {
		unwindAndReset();
		tokens_.push(scanDirective());
	}

	/// Add DOCUMENT-START or DOCUMENT-END token.
	private void fetchDocumentIndicator(TokenID id)() if (id == TokenID.DocumentStart || id == TokenID.DocumentEnd) {
		unwindAndReset();

		Mark startMark = reader_.mark;
		reader_.popFrontN(3);
		tokens_.push(simpleToken!id(startMark, reader_.mark));
	}

	/// Aliases to add DOCUMENT-START or DOCUMENT-END token.
	private alias fetchDocumentStart = fetchDocumentIndicator!(TokenID.DocumentStart);
	private alias fetchDocumentEnd = fetchDocumentIndicator!(TokenID.DocumentEnd);

	/// Add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
	private Token fetchFlowCollectionStart(TokenID id)() {
		// '[' and '{' may start a simple key.
		savePossibleSimpleKey();
		// Simple keys are allowed after '[' and '{'.
		allowSimpleKey_ = true;
		++flowLevel_;

		Mark startMark = reader_.mark;
		reader_.popFront();
		return simpleToken!id(startMark, reader_.mark);
	}

	/// Aliases to add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
	private alias fetchFlowSequenceStart = fetchFlowCollectionStart!(TokenID.FlowSequenceStart);
	private alias fetchFlowMappingStart = fetchFlowCollectionStart!(TokenID.FlowMappingStart);

	/// Add FLOW-SEQUENCE-START or FLOW-MAPPING-START token.
	private Token fetchFlowCollectionEnd(TokenID id)() {
		// Reset possible simple key on the current level.
		removePossibleSimpleKey();
		// No simple keys after ']' and '}'.
		allowSimpleKey_ = false;
		--flowLevel_;

		Mark startMark = reader_.mark;
		reader_.popFront();
		return simpleToken!id(startMark, reader_.mark);
	}

	/// Aliases to add FLOW-SEQUENCE-START or FLOW-MAPPING-START token/
	private alias fetchFlowSequenceEnd = fetchFlowCollectionEnd!(TokenID.FlowSequenceEnd);
	private alias fetchFlowMappingEnd = fetchFlowCollectionEnd!(TokenID.FlowMappingEnd);

	/// Add FLOW-ENTRY token;
	private Token fetchFlowEntry() @safe {
		// Reset possible simple key on the current level.
		removePossibleSimpleKey();
		// Simple keys are allowed after ','.
		allowSimpleKey_ = true;

		Mark startMark = reader_.mark;
		reader_.popFront();
		return flowEntryToken(startMark, reader_.mark);
	}

	/// Additional checks used in block context in fetchBlockEntry and fetchKey.
	///
	/// Params:  type = String representing the token type we might need to add.
	///          id   = Token type we might need to add.
	private void blockChecks(string type, TokenID id)() @safe {
		enum context = type ~ " keys are not allowed here";
		// Are we allowed to start a key (not neccesarily a simple one)?
		enforce(allowSimpleKey_, new ScannerException(context, reader_.mark));

		if (addIndent(reader_.column)) {
			tokens_.push(simpleToken!id(reader_.mark, reader_.mark));
		}
	}

	/// Add BLOCK-ENTRY token. Might add BLOCK-SEQUENCE-START in the process.
	private void fetchBlockEntry() @safe {
		if (flowLevel_ == 0) {
			blockChecks!("Sequence", TokenID.BlockSequenceStart)();
		}

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
	private void fetchKey() @safe {
		if (flowLevel_ == 0) {
			blockChecks!("Mapping", TokenID.BlockMappingStart)();
		}

		// Reset possible simple key on the current level.
		removePossibleSimpleKey();
		// Simple keys are allowed after '?' in the block context.
		allowSimpleKey_ = (flowLevel_ == 0);

		Mark startMark = reader_.mark;
		reader_.popFront();
		tokens_.push(keyToken(startMark, reader_.mark));
	}

	/// Add VALUE token. Might add KEY and/or BLOCK-MAPPING-START in the process.
	private void fetchValue() @safe {
		//Do we determine a simple key?
		if (possibleSimpleKeys_.length > flowLevel_ && !possibleSimpleKeys_[flowLevel_].isNull) {
			const key = possibleSimpleKeys_[flowLevel_];
			possibleSimpleKeys_[flowLevel_].isNull = true;
			Mark keyMark = Mark(key.line, key.column);
			const idx = key.tokenIndex - tokensTaken_;

			assert(idx >= 0);

			// Add KEY.
			Token[] tokens;
			while (!tokens_.empty)
				tokens ~= tokens_.pop();
			assert(tokens_.empty);
			// Manually inserting since tokens are immutable (need linked list).
			foreach (i, token; tokens) {
				if (i == idx) {
					// If this key starts a new block mapping, we need to add BLOCK-MAPPING-START.
					if (flowLevel_ == 0 && addIndent(key.column))
						tokens_.push(blockMappingStartToken(keyMark, keyMark));
					tokens_.push(keyToken(keyMark, keyMark));
				}
				tokens_.push(token);
			}

			// There cannot be two simple keys in a row.
			allowSimpleKey_ = false;
		} // Part of a complex key
		else {
			// We can start a complex value if and only if we can start a simple key.
			enforce(flowLevel_ > 0 || allowSimpleKey_, new ScannerException("Mapping values are not allowed here", reader_.mark));

			// If this value starts a new block mapping, we need to add
			// BLOCK-MAPPING-START. It'll be detected as an error later by the parser.
			if (flowLevel_ == 0 && addIndent(reader_.column)) {
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
	private Token fetchAnchor_(TokenID id)() @safe if (id == TokenID.Alias || id == TokenID.Anchor) {
		// ALIAS/ANCHOR could be a simple key.
		savePossibleSimpleKey();
		// No simple keys after ALIAS/ANCHOR.
		allowSimpleKey_ = false;

		return scanAnchor(id);
	}

	/// Aliases to add ALIAS or ANCHOR token.
	private alias fetchAlias = fetchAnchor_!(TokenID.Alias);
	private alias fetchAnchor = fetchAnchor_!(TokenID.Anchor);

	/// Add TAG token.
	private Token fetchTag() {
		//TAG could start a simple key.
		savePossibleSimpleKey();
		//No simple keys after TAG.
		allowSimpleKey_ = false;

		return scanTag();
	}

	/// Add block SCALAR token.
	private void fetchBlockScalar(ScalarStyle style)() if (style == ScalarStyle.Literal || style == ScalarStyle.Folded) {
		// Reset possible simple key on the current level.
		removePossibleSimpleKey();
		// A simple key may follow a block scalar.
		allowSimpleKey_ = true;

		auto blockScalar = scanBlockScalar(style);
		tokens_.push(blockScalar);
	}

	/// Aliases to add literal or folded block scalar.
	private alias fetchLiteral = fetchBlockScalar!(ScalarStyle.Literal);
	private alias fetchFolded = fetchBlockScalar!(ScalarStyle.Folded);

	/// Add quoted flow SCALAR token.
	private Token fetchFlowScalar(ScalarStyle quotes)() @safe {
		// A flow scalar could be a simple key.
		savePossibleSimpleKey();
		// No simple keys after flow scalars.
		allowSimpleKey_ = false;

		// Scan and add SCALAR.
		return scanFlowScalar(quotes);
	}

	/// Aliases to add single or double quoted block scalar.
	private alias fetchSingle = fetchFlowScalar!(ScalarStyle.SingleQuoted);
	private alias fetchDouble = fetchFlowScalar!(ScalarStyle.DoubleQuoted);

	/// Add plain SCALAR token.
	private void fetchPlain() @safe {
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
	private bool checkDirective() @safe {
		return reader_.startsWith('%') && reader_.column == 0;
	}

	/// Check if the next token is DOCUMENT-START:   ^ '---' (' '|'\n')
	private bool checkDocumentStart() @safe {
		return checkSequence!"---";
	}

	/// Check if the next token is DOCUMENT-END:     ^ '...' (' '|'\n')
	private bool checkDocumentEnd() @safe {
		return checkSequence!"...";
	}

	private bool checkSequence(string T)() @safe {
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
		if (!readerCopy.startsWith(allWhiteSpace))
			return false;
		return true;
	}

	/// Check if the next token is BLOCK-ENTRY:      '-' (' '|'\n')
	private bool checkBlockEntry() @safe {
		return !!reader_.save().drop(1).startsWith(allWhiteSpace);
	}

	/// Check if the next token is KEY(flow context):    '?'
	///
	/// or KEY(block context):   '?' (' '|'\n')
	private bool checkKey() @safe {
		return flowLevel_ > 0 || reader_.save().drop(1).startsWith(allWhiteSpace);
	}

	/// Check if the next token is VALUE(flow context):  ':'
	///
	/// or VALUE(block context): ':' (' '|'\n')
	private bool checkValue() @safe {
		return flowLevel_ > 0 || reader_.save().drop(1).startsWith(allWhiteSpace);
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
	private bool checkPlain() @safe {
		const c = reader_.front;
		if (!c.among!(allWhiteSpacePlusQuotesAndSlashes, curlyBraces, squareBrackets, '-', '?', ',', '#', '&', '*', '!', '|', '>', '%', '@', '`')) {
			return true;
		}
		return !reader_.save().drop(1).front.among!(allWhiteSpace) && (c == '-' || (flowLevel_ == 0 && c.among!('?', ':')));
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
	private void scanToNextToken() @safe {
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

		for (;;) {
			reader_.skipToNextNonSpace();
			if (reader_.startsWith('#')) {
				reader_.popToNextBreak();
			}
			if (reader_.popLineBreak() != '\0') {
				if (flowLevel_ == 0) {
					allowSimpleKey_ = true;
				}
			} else {
				break;
			}
		}
	}

	/// Scan directive token.
	private Token scanDirective() {
		Mark startMark = reader_.mark;
		// Skip the '%'.
		reader_.popFront();

		// Scan directive name
		const name = reader_.popDirectiveName();

		// Index where tag handle ends and suffix starts in a tag directive value.
		size_t tagHandleEnd = size_t.max;
		dstring value;
		if (name == "YAML") {
			value = reader_.popYAMLDirectiveValue();
		} else if (name == "TAG") {
			value = reader_.popTagDirectiveValue(tagHandleEnd);
		}

		Mark endMark = reader_.mark;

		DirectiveType directive;
		if (name == "YAML") {
			directive = DirectiveType.YAML;
		} else if (name == "TAG") {
			directive = DirectiveType.TAG;
		} else {
			directive = DirectiveType.Reserved;
			reader_.popToNextBreak();
		}

		reader_.skipDirectiveIgnoredLine();
		return directiveToken(startMark, endMark, value.toUTF8, directive, tagHandleEnd);
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
	private Token scanAnchor(const TokenID id) @safe {
		const startMark = reader_.mark;
		const dchar i = reader_.front;
		reader_.popFront();

		dstring value;
		if (i == '*') {
			value = reader_.popAlphaNumeric("an alias");
		} else {
			value = reader_.popAlphaNumeric("an anchor");
		}

		enforce(reader_.startsWith(allWhiteSpace, '?', ':', ',', ']', '}', '%', '@'), new UnexpectedTokenException(i == '*' ? "alias" : "anchor", "alphanumeric, '-' or '_'", reader_));
		switch (id) {
			case TokenID.Alias:
				return aliasToken(startMark, reader_.mark, value.toUTF8);
			case TokenID.Anchor:
				return anchorToken(startMark, reader_.mark, value.toUTF8);
			default:
				assert(false, "Invalid token reached");
		}
	}

	/// Scan a tag token.
	private Token scanTag() {
		const startMark = reader_.mark;
		dchar c = reader_.save().drop(1).front;
		dstring slice;
		size_t handleEnd;

		if (c == '<') {
			reader_.popFrontN(2);

			handleEnd = 0;
			slice ~= reader_.popTagURI("tag");
			enforce(reader_.startsWith('>'), new UnexpectedTokenException("tag", "'>'", reader_));
			reader_.popFront();
		} else if (c.among!(allWhiteSpace)) {
			reader_.popFront();
			handleEnd = 0;
			slice ~= '!';
		} else {
			uint length = 1;
			bool useHandle = false;

			while (!c.among!(allWhiteSpace)) {
				if (c == '!') {
					useHandle = true;
					break;
				}
				++length;
				c = reader_.save().drop(length).front;
			}

			if (useHandle) {
				slice ~= reader_.popTagHandle("tag");
				handleEnd = slice.length;
			} else {
				reader_.popFront();
				slice ~= '!';
				handleEnd = slice.length;
			}

			slice ~= reader_.popTagURI("tag");
		}

		enforce(reader_.startsWith(allWhiteSpace), new UnexpectedTokenException("tag", "' '", reader_));

		return tagToken(startMark, reader_.mark, slice.toUTF8, handleEnd);
	}

	/// Scan a block scalar token with specified style.
	private Token scanBlockScalar(const ScalarStyle style) @safe {
		const startMark = reader_.mark;
		// Scan the header.
		reader_.popFront();

		const indicators = reader_.popBlockScalarIndicators();

		const chomping = indicators[0];
		const increment = indicators[1];
		reader_.skipBlockScalarIgnoredLine();

		// Determine the indentation level and go to the first non-empty line.
		size_t indent = max(1, indent_ + 1);

		dstring slice;
		dstring newSlice;
		// Read the first indentation/line breaks before the scalar.
		size_t startLen = 0;
		if (increment == int.min) {
			size_t indentation;
			newSlice ~= reader_.popBlockScalarIndentation(indentation);
			indent = max(indent, indentation);
		} else {
			indent += increment - 1;
			newSlice ~= reader_.popBlockScalarBreaks(indent);
		}
		Mark endMark = reader_.mark;

		dchar lineBreak = '\0';
		size_t fullLen = 0;
		// Scan the inner part of the block scalar.
		while (reader_.column == indent && !reader_.empty) {
			slice ~= newSlice;
			newSlice = [];
			const bool leadingNonSpace = !reader_.front.among!(whiteSpaces);
			// This is where the 'interesting' non-whitespace data gets read.
			slice ~= reader_.popToNextBreak();
			lineBreak = reader_.popLineBreak();

			fullLen = slice.length + newSlice.length;
			startLen = 0;
			// The line breaks should actually be written _after_ the if() block
			// below. We work around that by inserting
			newSlice ~= reader_.popBlockScalarBreaks(indent);

			// This will not run during the last iteration (see the if() vs the
			// while()), hence breaksTransaction rollback (which happens after this
			// loop) will never roll back data written in this if() block.
			if (reader_.column == indent && !reader_.empty) {
				// Unfortunately, folding rules are ambiguous.

				// This is the folding according to the specification:
				if (style == ScalarStyle.Folded && lineBreak == '\n' && leadingNonSpace && !reader_.front.among!(whiteSpaces)) {
					if (startLen == newSlice.length) {
						newSlice ~= ' ';
					}
				} else {
					newSlice = chain(newSlice[0 .. startLen], [lineBreak], newSlice[startLen .. $]).array;
				}
			} else {
				break;
			}
		}

		// If chompint is Keep, we keep (commit) the last scanned line breaks
		// (which are at the end of the scalar). Otherwise re remove them (end the
		// transaction).
		if (chomping == Chomping.Keep) {
			slice ~= newSlice;
		}
		if (chomping != Chomping.Strip && lineBreak != '\0') {
			// If chomping is Keep, we keep the line break but the first line break
			// that isn't stripped (since chomping isn't Strip in this branch) must
			// be inserted _before_ the other line breaks.
			if (chomping == Chomping.Keep) {
				slice = chain(slice[0 .. fullLen], [lineBreak], slice[fullLen .. $]).array;
			} // If chomping is not Keep, breaksTransaction was cancelled so we can
			// directly write the first line break (as it isn't stripped - chomping
			// is not Strip)
		else {
				slice ~= lineBreak;
			}
		}

		return scalarToken(startMark, endMark, slice.toUTF8, style);
	}

	/// Scan a quoted flow scalar token with specified quotes.
	private Token scanFlowScalar(const ScalarStyle quotes) @safe {
		const startMark = reader_.mark;
		const quote = reader_.front;
		reader_.popFront();

		dstring slice = reader_.popFlowScalarNonSpaces(quotes);

		while (!reader_.empty && reader_.front != quote) {
			slice ~= reader_.popFlowScalarSpaces();
			slice ~= reader_.popFlowScalarNonSpaces(quotes);
		}
		enforce(!reader_.empty, new UnexpectedSequenceException("quoted flow scalar", "EOF"));
		reader_.popFront();

		return scalarToken(startMark, reader_.mark, slice.toUTF8, quotes);
	}

	/// Scan plain scalar token (no block, no quotes).
	private Token scanPlain() @safe {
		// We keep track of the allowSimpleKey_ flag here.
		// Indentation rules are loosed for the flow context
		const startMark = reader_.mark;
		Mark endMark = startMark;
		const indent = indent_ + 1;

		// We allow zero indentation for scalars, but then we need to check for
		// document separators at the beginning of the line.
		// if(indent == 0) { indent = 1; }

		dstring slice;
		dstring newSlice;
		// Stop at a comment.
		while (!reader_.startsWith('#')) {
			// Scan the entire plain scalar.
			auto l = reader_.popScalar(flowLevel_);
			if (l.length == 0)
				break;
			newSlice ~= l;
			endMark = reader_.mark;
			allowSimpleKey_ = false;

			slice ~= newSlice;
			newSlice = [];

			const startLength = slice.length;
			newSlice ~= reader_.popPlainSpaces(allowSimpleKey_);
			if (startLength == newSlice.length + slice.length || (flowLevel_ == 0 && reader_.column < indent)) {
				break;
			}
		}

		return scalarToken(startMark, endMark, slice.toUTF8, ScalarStyle.Plain);
	}
}
//TODO: split into two funcs
package auto popScalar(T)(ref T reader, in int flowLevel) if (isForwardYAMLStream!T) {
	dchar c = void;
	size_t length;
	// Moved the if() out of the loop for optimization.
	if (flowLevel == 0) {
		auto savedReader = reader.save();
		c = savedReader.front;
		for (;;) {
			if (savedReader.empty)
				break;
			savedReader.popFront();
			if (c.among!(allWhiteSpace) || (c == ':' && (savedReader.empty || savedReader.front.among!(allWhiteSpace)))) {
				break;
			}
			++length;
			if (savedReader.empty)
				break;
			c = savedReader.front;
		}
	} else {
		auto readerCopy = reader.save();
		for (;;) {
			if (readerCopy.front.among!(allWhiteSpace, ',', ':', '?', squareBrackets, curlyBraces)) {
				break;
			}
			readerCopy.popFront();
			++length;
		}
		// It's not clear what we should do with ':' in the flow context.
		if (readerCopy.front == ':' && (!readerCopy.drop(1).startsWith(allWhiteSpace, ',', squareBrackets, curlyBraces))) {
			throw new UnexpectedSequenceException("plain scalar", ":");
		}
	}

	auto output = reader.takeExactly(length).array;
	static if (isArray!T)
		reader.popFrontN(length);
	return output;
}

@safe pure unittest {
	static assert(worksWithForwardYAMLStreams!(x => { return popScalar(x, 0); }));
	auto test = "simpleword ";
	assert(test.popScalar(0) == "simpleword");
	assert(test == " ");

	test = "aaa:";
	assertThrown(test.popScalar(1));

	test = ":";
	assertThrown(test.popScalar(1));

	test = ":";
	assert(test.popScalar(0) == "");
	assert(test == ":");

	test = ": ";
	assert(test.popScalar(0) == "");
	assert(test == ": ");

	test = "test: ";
	assert(test.popScalar(0) == "test");
	assert(test == ": ");

	test = "yep,";
	assert(test.popScalar(1) == "yep");
	assert(test == ",");
}
/// Move to the next non-space character.
package void skipToNextNonSpace(T)(ref T reader) if (isYAMLStream!T) {
	auto length = reader.until!(x => x != ' ').walkLength;
	static if (isArray!T)
		reader.popFrontN(length);
}

@safe pure unittest {
	static assert(worksWithYAMLStreams!skipToNextNonSpace);
	auto str = "";
	str.skipToNextNonSpace();
	assert(str == "");
	str = "        c";
	str.skipToNextNonSpace();
	assert(str == "c");
}
/// Scan a string of alphanumeric or "-_" characters.
package auto popAlphaNumeric(T)(ref T reader, string name = "alphanumeric") if (isYAMLStream!T) {
	auto output = reader.until!(x => !(x.isAlphaNum || x.among!('-', '_'))).array;
	enforce(!output.empty, new UnexpectedTokenException(name, "alphanumeric, '-', or '_'", reader));
	static if (isArray!T)
		reader.popFrontN(output.length);
	return output;
}

@safe pure unittest {
	static assert(worksWithYAMLStreams!popAlphaNumeric);
	auto str = "";
	assertThrown(str.popAlphaNumeric());
	str = "1234";
	assert(str.popAlphaNumeric() == "1234");
	assert(str == "");
	str = "abc";
	assert(str.popAlphaNumeric() == "abc");
	assert(str == "");
	str = "1234abc";
	assert(str.popAlphaNumeric() == "1234abc");
	assert(str == "");
	str = "12 34";
	assert(str.popAlphaNumeric() == "12");
	assert(str == " 34");
	str = " 1234";
	assertThrown(str.popAlphaNumeric());
}
/// Scan all characters until next line break.
package auto popToNextBreak(T)(ref T reader) if (isYAMLStream!T) {
	return reader.until!(x => x.among!allBreaks).array;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popToNextBreak);
	auto str = "";
	assert(str.popToNextBreak() == "");
}
/// Scan name of a directive token.
package auto popDirectiveName(T)(ref T reader) if (isYAMLStream!T) {
	// Scan directive name.
	auto output = reader.popAlphaNumeric("a directive");
	enforce(reader.startsWith(allWhiteSpace), new UnexpectedTokenException("directive", "alphanumeric, '-' or '_'", reader));
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popDirectiveName);
	auto str = "";
	assertThrown(str.popDirectiveName());
	str = "test ";
	assert(str.popDirectiveName() == "test");
	assert(str == " ");
}
/// Scan value of a YAML directive token. Returns major, minor version separated by '.'.
package auto popYAMLDirectiveValue(T)(ref T reader) if (isYAMLStream!T) {
	dstring output;
	reader.skipToNextNonSpace();

	output ~= reader.popYAMLDirectiveNumber();

	enforce(reader.startsWith('.'), new UnexpectedTokenException("directive", "digit or '.'", reader));
	// Skip the '.'.
	reader.popFront();

	output ~= '.';
	output ~= reader.popYAMLDirectiveNumber();

	enforce(reader.startsWith(allWhiteSpace), new UnexpectedTokenException("directive", "digit or '.'", reader));
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popYAMLDirectiveValue);
	auto str = "";
	assertThrown(str.popYAMLDirectiveValue());
	str = "1.2 ";
	assert(str.popYAMLDirectiveValue() == "1.2");
	assert(str == " ");
}
/// Scan a number from a YAML directive.
package auto popYAMLDirectiveNumber(T)(ref T reader) if (isYAMLStream!T) {
	enforce(!reader.empty, new UnexpectedTokenException("directive", "digit", reader));
	enforce(reader.front.isDigit, new UnexpectedTokenException("directive", "digit", reader));
	auto output = reader.until!(x => x.isDigit)(OpenRight.no).array;
	static if (isArray!T)
		reader.popFrontN(output.length);
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popYAMLDirectiveNumber);
	auto str = "";
	assertThrown(str.popYAMLDirectiveNumber());
	str = "1 ";
	assert(str.popYAMLDirectiveNumber() == "1");
	assert(str == " ");
}
/// Scan value of a tag directive.
///
/// Returns: Length of tag handle (which is before tag prefix) in scanned data
package auto popTagDirectiveValue(T)(ref T reader, out size_t handleLength) if (isForwardYAMLStream!T) {
	dstring output;
	reader.skipToNextNonSpace();
	output ~= reader.popTagDirectiveHandle();
	handleLength = output.length;
	reader.skipToNextNonSpace();
	output ~= reader.popTagDirectivePrefix();

	return output;
}
/*@safe pure*/
unittest { //ADD MORE
	static assert(worksWithForwardYAMLStreams!(x => { size_t whatever; return popTagDirectiveValue(x, whatever); }));

	auto str = "";
	size_t handleLength;
	assertThrown(str.popTagDirectiveValue(handleLength));
	str = " !! !test ";
	assert(str.popTagDirectiveValue(handleLength) == "!!!test");
	assert(handleLength == 2);
	assert(str == " ");
}

/// Scan handle of a tag directive.
package auto popTagDirectiveHandle(T)(ref T reader) if (isForwardYAMLStream!T) {
	auto output = reader.popTagHandle("directive");
	enforce(reader.startsWith(' '), new UnexpectedTokenException("directive", "' '", reader));
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithForwardYAMLStreams!popTagDirectiveHandle);
	auto str = "";
	assertThrown(str.popTagDirectiveHandle());
	str = "!! ";
	assert(str.popTagDirectiveHandle() == "!!");
}

/// Scan prefix of a tag directive.
package auto popTagDirectivePrefix(T)(ref T reader) if (isYAMLStream!T) {
	auto output = reader.popTagURI("directive");
	enforce(reader.startsWith(allWhiteSpace), new UnexpectedTokenException("directive", "' '", reader));
	return output;
}
/*@safe pure*/
unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popTagDirectivePrefix);
	auto str = "";
	assertThrown(str.popTagDirectivePrefix());
	str = " ";
	assertThrown(str.popTagDirectivePrefix());
}

/// Scan (and ignore) ignored line after a directive.
package void skipDirectiveIgnoredLine(T)(ref T reader) if (isYAMLStream!T) {
	reader.skipToNextNonSpace();
	if (reader.empty)
		return;
	if (reader.startsWith('#')) {
		reader.popToNextBreak();
	}
	enforce(reader.startsWith(allBreaks), new UnexpectedTokenException("directive", "comment or a line break", reader));
	reader.popLineBreak();
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!skipDirectiveIgnoredLine);
	auto str = "";
	assertNotThrown(str.skipDirectiveIgnoredLine());
	str = "\n";
	assertNotThrown(str.skipDirectiveIgnoredLine());
	assert(str == "");
}
/// Scan chomping and indentation indicators of a scalar token.
package Tuple!(Chomping, int) popBlockScalarIndicators(T)(ref T reader) if (isYAMLStream!T) {
	auto chomping = Chomping.Clip;
	int increment = int.min;
	if (reader.empty)
		return tuple(chomping, increment);
	dchar c = reader.front;

	/// Indicators can be in any order.
	if (getChomping(reader, c, chomping)) {
		getIncrement(reader, c, increment);
	} else if (getIncrement(reader, c, increment)) {
		getChomping(reader, c, chomping);
	}

	enforce(c.among!(allWhiteSpace), new UnexpectedTokenException("block scalar", "chomping or indentation indicator", reader));

	return tuple(chomping, increment);
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!popBlockScalarIndicators);
	auto str = "";
	assert(str.popBlockScalarIndicators() == tuple(Chomping.Clip, int.min));
	str = " ";
	assert(str.popBlockScalarIndicators() == tuple(Chomping.Clip, int.min));
}
/// Get chomping indicator, if detected. Return false otherwise.
///
/// Used in popBlockScalarIndicators.
///
/// Params:
///
/// reader   = The YAML stream being read from.
/// c        = The character that may be a chomping indicator.
/// chomping = Write the chomping value here, if detected.
package bool getChomping(T)(ref T reader, ref dchar c, ref Chomping chomping) if (isYAMLStream!T) {
	if (!c.among!(chompIndicators)) {
		return false;
	}
	chomping = c == '+' ? Chomping.Keep : Chomping.Strip;
	reader.popFront();
	c = reader.front;
	return true;
}

@safe pure unittest { //ADD MORE
	dchar c;
	Chomping chomping;
	auto str = "";
	assert(str.getChomping(c, chomping) == false);
}
/// Get increment indicator, if detected. Return false otherwise.
///
/// Used in popBlockScalarIndicators.
///
/// Params:
///
/// reader    = The YAML stream being read from.
/// c         = The character that may be an increment indicator.
///             If an increment indicator is detected, this will be updated to
///             the next character in the Reader.
/// increment = Write the increment value here, if detected.
package bool getIncrement(T)(ref T reader, ref dchar c, ref int increment) if (isYAMLStream!T) {
	if (!c.isDigit) {
		return false;
	}
	// Convert a digit to integer.
	increment = c - '0';
	assert(increment < 10 && increment >= 0, "Digit has invalid value");
	enforce(increment > 0, new UnexpectedTokenException("block scalar", "1-9", reader));

	reader.popFront();
	c = reader.front;
	return true;
}

@safe pure unittest { //ADD MORE
	dchar c;
	int inc;
	auto str = "";
	assert(str.getIncrement(c, inc) == false);
}
/// Scan (and ignore) ignored line in a block scalar.
package void skipBlockScalarIgnoredLine(T)(ref T reader) if (isYAMLStream!T) {
	reader.skipToNextNonSpace();
	enforce(!reader.empty, new UnexpectedTokenException("block scalar", "comment or line break", reader));
	if (reader.startsWith('#')) {
		reader.popToNextBreak();
	}

	enforce(reader.front.among!(allBreaks), new UnexpectedTokenException("block scalar", "comment or line break", reader));

	reader.popLineBreak();
	return;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!skipBlockScalarIgnoredLine);
	auto str = "";
	assertThrown(str.skipBlockScalarIgnoredLine());
	str = "\n";
	assertNotThrown(str.skipBlockScalarIgnoredLine());
}
/// Scan indentation in a block scalar, returning line breaks and max indent.
package auto popBlockScalarIndentation(T)(ref T reader, out size_t maxIndent) if (isYAMLStream!T) {
	dstring output;
	while (reader.startsWith(newLinesPlusSpaces)) {
		if (reader.front != ' ') {
			output ~= reader.popLineBreak();
			continue;
		}
		reader.popFront();
		maxIndent = max(reader.column, maxIndent);
	}

	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!(x => { size_t whatever; return popBlockScalarIndentation(x, whatever); }));
	auto str = "";
	size_t maxIndent;
	assert(str.popBlockScalarIndentation(maxIndent) == "");
	assert(maxIndent == 0);
}
/// Scan line breaks at lower or specified indentation in a block scalar.
package auto popBlockScalarBreaks(T)(ref T reader, const size_t indent) if (isYAMLStream!T) {
	dstring output;

	while (!reader.empty) {
		while (reader.startsWith(' ') && reader.column < indent) {
			reader.popFront();
		}
		if (!reader.front.among!(newLines)) {
			break;
		}
		output ~= reader.popLineBreak();
	}

	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithYAMLStreams!(x => popBlockScalarBreaks(x, 0)));
	auto str = "";
	assert(str.popBlockScalarBreaks(0) == "");
}
/// Scan nonspace characters in a flow scalar.
package auto popFlowScalarNonSpaces(T)(ref T reader, const ScalarStyle quotes) if (isForwardYAMLStream!T) {
	dstring output;
	for (;;)
		with (ScalarStyle) {
			auto buf = reader.until!(x => x.among!(allWhiteSpacePlusQuotesAndSlashes)).array;

			static if (isArray!T)
				reader.popFrontN(buf.length);

			output ~= buf;
			if (quotes == SingleQuoted && reader.startsWith('\'') && reader.save().drop(1).startsWith('\'')) {
				reader.popFrontN(2);
				output ~= '\'';
			} else if ((quotes == DoubleQuoted && reader.startsWith('\'')) || (quotes == SingleQuoted && reader.startsWith('"', '\\'))) {
				output ~= reader.front;
				reader.popFront();
			} else if (quotes == DoubleQuoted && reader.startsWith('\\')) {
				reader.popFront();
				if (reader.startsWith(wyaml.escapes.escapeSeqs)) {
					output ~= ['\\', reader.front];
					reader.popFront();
				} else if (reader.startsWith(wyaml.escapes.escapeHexSeq)) {
					const hexLength = wyaml.escapes.escapeHexLength(reader.front);
					output ~= '\\';
					output ~= reader.front;
					reader.popFront();

					auto v = reader.take(hexLength);
					auto hex = v.save().array;
					enforce(hex.length == hexLength, new UnexpectedTokenException("double quoted scalar", "escape sequence of " ~ hexLength.text ~ " hexadecimal numbers", reader));
					enforce(v.all!isHexDigit, new UnexpectedTokenException("double quoted scalar", "escape sequence of hexadecimal numbers", v.find!(x => !x.isHexDigit)));

					output ~= hex;
					static if (isArray!T)
						reader.popFrontN(hexLength);
				} else if (reader.startsWith(newLines)) {
					reader.popLineBreak();
					output ~= reader.popFlowScalarBreaks();
				} else {
					throw new UnexpectedTokenException("double quoted scalar", "valid escape character", reader);
				}
			} else
				break;
		}
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithForwardYAMLStreams!(x => popFlowScalarNonSpaces(x, ScalarStyle.SingleQuoted)));
	auto str = "";
	assert(str.popFlowScalarNonSpaces(ScalarStyle.SingleQuoted) == "");
	assert(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted) == "");
	assert(str == "");

	str = "'";
	assert(str.popFlowScalarNonSpaces(ScalarStyle.SingleQuoted) == "");
	assert(str == "'");
	str = "'";
	assert(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted) == "'");
	assert(str == "");

	str = "aaa";
	assert(str.popFlowScalarNonSpaces(ScalarStyle.SingleQuoted) == "aaa");
	assert(str == "");
	str = "aaa";
	assert(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted) == "aaa");
	assert(str == "");

	str = `\u4000`;
	assert(str.popFlowScalarNonSpaces(ScalarStyle.SingleQuoted) == `\u4000`);
	assert(str == "");
	str = `\u4000`;
	assert(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted) == `\u4000`);
	assert(str == "");

	str = `\u400`;
	assert(str.popFlowScalarNonSpaces(ScalarStyle.SingleQuoted) == `\u400`);
	assert(str == "");
	str = `\u400`;
	assertThrown(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted));
	str = `\u40h0`;
	assertThrown(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted));
	str = `\u`;
	assertThrown(str.popFlowScalarNonSpaces(ScalarStyle.DoubleQuoted));
}
/// Scan space characters in a flow scalar.
package auto popFlowScalarSpaces(T)(ref T reader) if (isYAMLStream!T) {
	dstring output;
	dstring whitespaces = reader.until!(x => !x.among!whiteSpaces).array.to!dstring;
	static if (isArray!T)
		reader.popFrontN(whitespaces.length);

	// Spaces not followed by a line break.
	if (!reader.startsWith(newLines))
		return whitespaces;

	// There's a line break after the spaces.
	const lineBreak = reader.popLineBreak();

	if (lineBreak != '\n') {
		output ~= lineBreak;
	}

	bool extraBreaks;
	output ~= reader.popFlowScalarBreaks(extraBreaks);

	// No extra breaks, one normal line break. Replace it with a space.
	if (lineBreak == '\n' && !extraBreaks) {
		output ~= ' ';
	}

	return output;
}

@safe pure unittest {
	static assert(worksWithForwardYAMLStreams!popFlowScalarSpaces);
	auto str = "";
	assert(str.popFlowScalarSpaces() == "");
	str = " ";
	assert(str.popFlowScalarSpaces() == " ");
	str = " \n";
	assert(str.popFlowScalarSpaces() == " ");
	str = " a";
	assert(str.popFlowScalarSpaces() == " ");
	assert(str == "a");
	str = "\ta";
	assert(str.popFlowScalarSpaces() == "\t");
	assert(str == "a");
	str = "  \t\t \ta";
	assert(str.popFlowScalarSpaces() == "  \t\t \t");
	assert(str == "a");
	str = " \na"; //is this behaviour correct...?
	assert(str.popFlowScalarSpaces() == " ");
	assert(str == "a");
}
/// Scan line breaks in a flow scalar.
package dstring popFlowScalarBreaks(T)(ref T reader) if (isYAMLStream!T) {
	bool waste;
	return reader.popFlowScalarBreaks(waste);
}

package auto popFlowScalarBreaks(T)(ref T reader, out bool extraBreaks) if (isForwardYAMLStream!T) {
	dstring output;
	for (;;) {
		if (reader.empty)
			break;
		// Instead of checking indentation, we check for document separators.
		enforce(!reader.end(), new UnexpectedSequenceException("quoted scalar", "document separator"));

		// Skip any whitespaces.
		reader.until!(x => !x.among!whiteSpaces).walkLength;

		// Encountered a non-whitespace non-linebreak character, so we're done.
		if (!reader.startsWith(newLines))
			break;

		extraBreaks = true;
		output ~= reader.popLineBreak();
	}
	return output;
}

@safe pure unittest {
	static assert(worksWithForwardYAMLStreams!(x => { bool whatever; return popFlowScalarBreaks(x, whatever); }));
	auto str = "     ";
	assert(str.popFlowScalarBreaks() == "");

	str = " \n  ";
	assert(str.popFlowScalarBreaks() == "");
}

package bool end(T)(T reader) if (isForwardYAMLStream!T) {
	if (reader.empty)
		return true;
	auto savedReader = reader.save();
	if (savedReader.take(3).array.among!("---"d, "..."d)) {
		static if (isArray!T)
			savedReader.popFrontN(3);
		if (savedReader.empty || savedReader.startsWith(allWhiteSpace))
			return true;
	}
	return false;
}

@safe pure unittest {
	static assert(worksWithForwardYAMLStreams!end);
	assert("---\r\n".end);
	assert("...\n".end);
	assert(!"...a".end);
	assert("---".end);
	assert("".end);
}
/// Scan spaces in a plain scalar.
package auto popPlainSpaces(T)(ref T reader, ref bool allowSimpleKey_) if (isForwardYAMLStream!T) {
	dstring output;
	// The specification is really confusing about tabs in plain scalars.
	// We just forbid them completely. Do not use tabs in YAML!

	// Get as many plain spaces as there are.
	dstring whitespaces = reader.until!(x => x != ' ').array.to!dstring;
	// No newline after the spaces (if any)
	if (!reader.startsWith(newLines))
		return whitespaces;

	// Newline after the spaces (if any)
	const lineBreak = reader.popLineBreak();
	allowSimpleKey_ = true;

	if (reader.end)
		return output;

	bool extraBreaks = false;

	if (lineBreak != '\n') {
		output ~= lineBreak;
	}
	while (reader.startsWith(newLinesPlusSpaces)) {
		if (reader.startsWith(' ')) {
			reader.popFront();
		} else {
			extraBreaks = true;
			output ~= reader.popLineBreak();

			if (reader.end)
				return output;
		}
	}

	// No line breaks, only a space.
	if (lineBreak == '\n' && !extraBreaks) {
		output ~= ' ';
	}
	return output;
}

@safe pure unittest { //ADD MORE
	static assert(worksWithForwardYAMLStreams!(x => { bool tf; return popPlainSpaces(x, tf); }));
	auto str = "";
	bool allowSimpleKey;
	assert(str.popPlainSpaces(allowSimpleKey) == "");
}
/// Scan handle of a tag token.
package auto popTagHandle(T)(ref T reader, string name = "tag handle") if (isForwardYAMLStream!T) {
	enforce(reader.startsWith('!'), new UnexpectedTokenException(name, "'!'", reader));

	uint length = 1;
	dchar c = reader.save().drop(length).front;
	if (c != ' ') {
		while (c.isAlphaNum || c.among!('-', '_')) {
			++length;
			c = reader.save().drop(length).front;
		}
		enforce(c == '!', new UnexpectedTokenException(name, "'!'", only(c)));
		++length;
	}

	auto output = reader.take(length).array;
	static if (isArray!T)
		reader.popFrontN(output.length);
	return output;
}

@safe pure unittest {
	static assert(worksWithForwardYAMLStreams!popTagHandle);
	auto str = "";
	assertThrown(str.popTagHandle());

	str = "a";
	assertThrown(str.popTagHandle());

	str = "!a ";
	assertThrown(str.popTagHandle());

	str = "!!wordswords ";
	assert(str.popTagHandle() == "!!");
	assert(str == "wordswords ");
}
/// Scan URI in a tag token.
package auto popTagURI(T)(ref T reader, string name = "URI") if (isYAMLStream!T) {
	// Note: we do not check if URI is well-formed.
	dstring output;
	while (!reader.empty && (reader.front.isAlphaNum || reader.front.among!(miscValidURIChars))) {
		if (reader.startsWith('%'))
			output ~= reader.popURIEscapes(name);
		if (reader.empty)
			break;
		output ~= reader.front;
		reader.popFront();
	}
	// OK if we scanned something, error otherwise.
	enforce(output.length > 0, new UnexpectedTokenException(name, "URI", reader));
	return output;
}
/*@safe pure*/
unittest {
	static assert(worksWithYAMLStreams!popTagURI);
	auto str = "";
	assertThrown(str.popTagURI());

	str = "http://example.com";
	assert(str.popTagURI() == "http://example.com");
	assert(str == "");

	str = "http://example.com/%20";
	assert(str.popTagURI() == "http://example.com/ ");
	assert(str == "");

	str = "http://example.com/ ";
	assert(str.popTagURI() == "http://example.com/");
	assert(str == " ");
}
/// Scan URI escape sequences.
package dstring popURIEscapes(T)(ref T reader, string name = "URI escape") if (isYAMLStream!T) {
	import std.uri : decodeComponent;

	dstring uriBuf;
	while (reader.startsWith('%')) {
		reader.popFront();
		uriBuf ~= '%';
		auto nextTwo = reader.take(2).array;
		static if (isArray!T)
			reader.popFrontN(2);
		if (!nextTwo.all!isHexDigit)
			throw new UnexpectedTokenException(name, "URI escape sequence with two hexadecimal numbers", nextTwo.until!(x => x.isHexDigit));
		uriBuf ~= nextTwo;
	}
	return decodeComponent(uriBuf).to!(dstring);
}
/*@safe pure*/
unittest {
	static assert(worksWithYAMLStreams!popURIEscapes);
	//it's a space!
	auto str = "%20";
	assert(str.popURIEscapes() == " ");
	assert(str == "");

	//not an escape
	str = "2";
	assert(str.popURIEscapes() == "");
	assert(str == "2");

	//empty
	str = "";
	assert(str.popURIEscapes() == "");
	assert(str == "");

	//invalid escape
	str = "%H";
	assertThrown(str.popURIEscapes());

	//2-byte char
	str = "%C3%A2";
	assert(str.popURIEscapes() == "â");
	assert(str == "");

	//3-byte char
	str = "%E2%9C%A8";
	assert(str.popURIEscapes() == "✨");
	assert(str == "");

	//4-byte char
	str = "%F0%9D%84%A0";
	assert(str.popURIEscapes() == "𝄠");
	assert(str == "");

	//two 1-byte chars
	str = "%20%20";
	assert(str.popURIEscapes() == "  ");
	assert(str == "");

	//ditto, but with non-escape char
	str = "%20%20s";
	assert(str.popURIEscapes() == "  ");
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
package dchar popLineBreak(T)(ref T reader) if (isYAMLStream!T) {
	if (reader.startsWith("\r\n")) {
		static if (isArray!T)
			reader.popFront();
		reader.popFront();
		return '\n';
	}
	switch (reader.startsWith('\r', '\n', '\x85', '\u2028', '\u2029')) {
		case 1, 2, 3:
			reader.popFront();
			return '\n';
		case 4, 5:
			scope (exit)
				reader.popFront();
			return reader.front;
		default:
			return '\0';
	}
}

@safe pure unittest {
	static assert(worksWithYAMLStreams!popLineBreak);
	string str = "\r\n";
	assert(str.popLineBreak() == '\n');
	assert(str == "");
	str = "\r";
	assert(str.popLineBreak() == '\n');
	assert(str == "");
	str = "\n";
	assert(str.popLineBreak() == '\n');
	assert(str == "");
	str = "\u0085";
	assert(str.popLineBreak() == '\n');
	assert(str == "");
	str = "\u2028";
	assert(str.popLineBreak() == '\u2028');
	assert(str == "");
	str = "\u2029";
	assert(str.popLineBreak() == '\u2029');
	assert(str == "");
	str = "";
	assert(str.popLineBreak() == '\0');
	assert(str == "");
	str = "b";
	assert(str.popLineBreak() == '\0');
	assert(str == "b");
	str = "\nb";
	assert(str.popLineBreak() == '\n');
	assert(str == "b");
}

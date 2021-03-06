//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * YAML emitter.
 * Code based on PyYAML: http://www.pyyaml.org
 */
module wyaml.emitter;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.exception;
import std.format;
import std.meta;
import std.range;
import std.string;
import std.system;
import std.typecons;
import std.utf;

import wyaml.anchor;
import wyaml.escapes;
import wyaml.event;
import wyaml.exception;
import wyaml.linebreak;
import wyaml.queue;
import wyaml.style;
import wyaml.tag;
import wyaml.tagdirective;

/**
 * Exception thrown at Emitter errors.
 *
 * See_Also:
 *     YAMLException
 */
package class EmitterException : YAMLException {
	mixin ExceptionCtors;
}

package enum ScalarFlags {
	none = 0,
	empty = 1 << 0,
	multiline = 1 << 1,
	allowFlowPlain = 1 << 2,
	allowBlockPlain = 1 << 3,
	allowSingleQuoted = 1 << 4,
	allowDoubleQuoted = 1 << 5,
	allowBlock = 1 << 6,
	isNull = 1 << 7
}
//Stores results of analysis of a scalar, determining e.g. what scalar style to use.
package align(4) struct ScalarAnalysis {
	//Scalar itself.
	string scalar;

	///Analysis results.
	BitFlags!ScalarFlags flags;
}
package enum YAMLVersion {
	v1 = "1.0",
	v2 = "1.1"
}

package alias unicodeNewLines = AliasSeq!('\u0085', '\u2028', '\u2029');
package alias newLines = AliasSeq!('\n', unicodeNewLines);
package alias flowIndicatorSeq = AliasSeq!(',', '?', '[', ']', '{', '}');
package alias specialCharSeq = AliasSeq!('#', ',', '[', ']', '{', '}', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`');

//Emits YAML events into a file/stream.
package struct Emitter(T) {
	invariant() {
		assert(bestIndent_ > 0 && bestIndent_ < 10, "Emitter bestIndent must be 1 to 9 for one-character indent hint");
	}
	private alias TagDirective = wyaml.tagdirective.TagDirective;

	///Stream to write to.
	private T stream_;

	///Stack of states.
	private bool delegate()[] states_;
	///Current state.
	private bool delegate() state_;

	///Event queue.
	private Queue!Event events_;
	///Event we're currently emitting.
	private auto event_() const pure nothrow @safe @nogc {
		return events_.peek();
	}

	///Stack of previous indentation levels.
	private int[] indents_;
	///Current indentation level.
	private int indent_ = -1;

	///Level of nesting in flow context. If 0, we're in block context.
	private uint flowLevel_ = 0;

	/// Describes context (where we are in the document).
	private enum Context {
		/// Root node of a document.
		Root,
		/// Sequence.
		Sequence,
		/// Mapping.
		MappingNoSimpleKey,
		/// Mapping, in a simple key.
		MappingSimpleKey
	}
	/// Current context.
	private Context context_;

	///Characteristics of the last emitted character:

	///Line.
	private uint line_ = 0;
	///Column.
	private uint column_ = 0;
	///Whitespace character?
	private bool whitespace_ = true;
	///indentation space, '-', '?', or ':'?
	private bool indentation_ = true;

	///Does the document require an explicit document indicator?
	private bool openEnded_;

	///Formatting details.

	///Canonical scalar format?
	private bool canonical_;
	///Best indentation width.
	private uint bestIndent_ = 2;
	///Best text width.
	private uint bestWidth_ = 80;
	///Best line break character/s.
	private LineBreak bestLineBreak_;

	///Tag directive handle - prefix pairs.
	private TagDirective[] tagDirectives_;

	///Anchor/alias to process.
	private string preparedAnchor_ = null;
	///Tag to process.
	private string preparedTag_ = null;

	///Analysis result of the current scalar.
	private ScalarAnalysis analysis_;
	///Style of the current scalar.
	private ScalarStyle style_ = ScalarStyle.Invalid;

	@disable int opCmp(ref Emitter!T) const;
	@disable bool opEquals(ref Emitter!T) const;
	@disable size_t toHash() nothrow @safe;

	/**
		 * Construct an emitter.
		 *
		 * Params:  stream    = Stream to write to. Must be writable.
		 *          canonical = Write scalars in canonical form?
		 *          indent    = Indentation width.
		 *          lineBreak = Line break character/s.
		 */
	public this(T stream, const bool canonical, const int indent, const int width, const LineBreak lineBreak) {
		states_.reserve(32);
		indents_.reserve(32);
		stream_ = stream;
		canonical_ = canonical;
		state_ = &expectStreamStart;

		if (indent > 1 && indent < 10) {
			bestIndent_ = indent;
		}
		if (width > bestIndent_ * 2) {
			bestWidth_ = width;
		}
		bestLineBreak_ = lineBreak;

		analysis_.flags |= ScalarFlags.isNull;
	}

	///Emit an event. Throws EmitterException on error.
	public void emit(Event event) {
		events_.push(event);
		while (!needMoreEvents()) {
			enforce(state_(), new YAMLException("Reached unexpected "~event_.idString));
			events_.pop();
		}
	}

	///Pop and return the newest state in states_.
	private bool delegate() popState() @safe pure nothrow @nogc {
		assert(states_.length > 0, "Emitter: Need to pop a state but there are no states left");
		const result = states_.back;
		states_.popBack();
		return result;
	}

	///Pop and return the newest indent in indents_.
	private int popIndent() @safe pure nothrow @nogc {
		assert(indents_.length > 0, "Emitter: Need to pop an indent level but there are no indent levels left");
		const result = indents_.back;
		indents_.popBack();
		return result;
	}

	///Write a string to the file/stream.
	private void writeString(const string str) {
		put(stream_, str);
	}

	///In some cases, we wait for a few next events before emitting.
	private bool needMoreEvents() nothrow const {
		if (events_.empty) {
			return true;
		}

		switch (events_.peek().id) {
			case EventID.DocumentStart:
				return needEvents(1);
			case EventID.SequenceStart:
				return needEvents(2);
			case EventID.MappingStart:
				return needEvents(3);
			default:
				return false;
		}
	}

	///Determines if we need specified number of more events.
	private bool needEvents(in uint count) nothrow const {
		int level = 0;
		foreach (event; events_) {
			switch (event.id) {
				//More events follow these
				case EventID.DocumentStart, EventID.SequenceStart, EventID.MappingStart:
					++level;
					break;
				//Marks end of related start events
				case EventID.DocumentEnd, EventID.SequenceEnd, EventID.MappingEnd:
					--level;
					if (level < 0) {
						return false;
					}
					break;
				//Reached end of document
				case EventID.StreamStart:
					return false;
				default: break;
			}
		}

		return events_.length < (count + 1);
	}

	///Increase indentation level.
	private void increaseIndent(const Flag!"flow" flow = No.flow, const bool indentless = false) nothrow {
		indents_ ~= indent_;
		if (indent_ == -1) {
			indent_ = flow ? bestIndent_ : 0;
		} else if (!indentless) {
			indent_ += bestIndent_;
		}
	}

	//Stream handlers.

	///Handle start of a file/stream.
	private bool expectStreamStart() nothrow {
		if (event_.id != EventID.StreamStart) {
			return false;
		}

		state_ = &expectDocumentStart!(Yes.first);
		return true;
	}

	///Expect nothing, throwing if we still have something.
	private bool expectNothing() const nothrow pure @safe @nogc {
		return false;
	}

	//Document handlers.

	///Handle start of a document.
	private bool expectDocumentStart(Flag!"first" first)() {
		if (!event_.id.among(EventID.DocumentStart, EventID.StreamEnd)) {
			return false;
		}

		if (event_.id == EventID.DocumentStart) {
			const yamlVersion = cast(YAMLVersion)event_.value;
			if (openEnded_ && (yamlVersion !is null || event_.tagDirectives !is null)) {
				writeIndicator("...", Yes.needWhitespace);
				writeIndent();
			}

			if (yamlVersion !is null) {
				writeVersionDirective(yamlVersion);
			}

			if (event_.tagDirectives !is null) {
				tagDirectives_ = event_.tagDirectives.dup;
				try {
					tagDirectives_.sort();
				} catch (Exception) {
					return false;
				}

				foreach (ref pair; tagDirectives_) {
					writeTagDirective(pair);
				}
			}

			//Add any default tag directives that have not been overriden.
			foreach (def; defaultTagDirectives) {
				if (!tagDirectives_.canFind(def)) {
					tagDirectives_ ~= def;
				}
			}

			const implicit = first && !event_.explicitDocument && !canonical_ && yamlVersion is null && event_.tagDirectives is null && !checkEmptyDocument();
			if (!implicit) {
				writeIndent();
				writeIndicator("---", Yes.needWhitespace);
				if (canonical_) {
					writeIndent();
				}
			}
			state_ = &expectRootNode;
		} else if (event_.id == EventID.StreamEnd) {
			if (openEnded_) {
				writeIndicator("...", Yes.needWhitespace);
				writeIndent();
			}
			state_ = &expectNothing;
		}
		return true;
	}

	///Handle end of a document.
	private bool expectDocumentEnd() {
		if (event_.id != EventID.DocumentEnd) {
			return false;
		}

		writeIndent();
		if (event_.explicitDocument) {
			writeIndicator("...", Yes.needWhitespace);
			writeIndent();
		}
		state_ = &expectDocumentStart!(No.first);
		return true;
	}

	///Handle the root node of a document.
	private bool expectRootNode() {
		states_ ~= &expectDocumentEnd;
		return expectNode(Context.Root);
	}

	///Handle a mapping node.
	//
	//Params: simpleKey = Are we in a simple key?
	private bool expectMappingNode(const bool simpleKey = false) {
		return expectNode(simpleKey ? Context.MappingSimpleKey : Context.MappingNoSimpleKey);
	}

	///Handle a sequence node.
	private bool expectSequenceNode() {
		return expectNode(Context.Sequence);
	}

	///Handle a new node. Context specifies where in the document we are.
	private bool expectNode(const Context context) {
		context_ = context;

		const flowCollection = event_.collectionStyle == CollectionStyle.Flow;

		switch (event_.id) {
			case EventID.Alias:
				expectAlias();
				break;
			case EventID.Scalar:
				processAnchor("&");
				processTag();
				expectScalar();
				break;
			case EventID.SequenceStart:
				processAnchor("&");
				processTag();
				if (flowLevel_ > 0 || canonical_ || flowCollection || checkEmptySequence()) {
					expectFlowSequence();
				} else {
					expectBlockSequence();
				}
				break;
			case EventID.MappingStart:
				processAnchor("&");
				processTag();
				if (flowLevel_ > 0 || canonical_ || flowCollection || checkEmptyMapping()) {
					expectFlowMapping();
				} else {
					expectBlockMapping();
				}
				break;
			default:
				return false;
		}
		return true;
	}
	///Handle an alias.
	private bool expectAlias() {
		if (event_.anchor.isNull()) {
			return false;
		}
		processAnchor("*");
		state_ = popState();
		return true;
	}

	///Handle a scalar.
	private void expectScalar() {
		increaseIndent(Yes.flow);
		processScalar();
		indent_ = popIndent();
		state_ = popState();
	}

	//Flow sequence handlers.

	///Handle a flow sequence.
	private void expectFlowSequence() {
		writeIndicator("[", Yes.needWhitespace, Yes.whitespace);
		++flowLevel_;
		increaseIndent(Yes.flow);
		state_ = &expectFlowSequenceItem!(Yes.first);
	}

	///Handle a flow sequence item.
	private bool expectFlowSequenceItem(Flag!"first" first)() {
		if (event_.id == EventID.SequenceEnd) {
			indent_ = popIndent();
			--flowLevel_;
			static if (!first)
				if (canonical_) {
					writeIndicator(",", No.needWhitespace);
					writeIndent();
				}
			writeIndicator("]", No.needWhitespace);
			state_ = popState();
			return true;
		}
		static if (!first) {
			writeIndicator(",", No.needWhitespace);
		}
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		states_ ~= &expectFlowSequenceItem!(No.first);
		return expectSequenceNode();
	}

	//Flow mapping handlers.

	///Handle a flow mapping.
	private bool expectFlowMapping() {
		writeIndicator("{", Yes.needWhitespace, Yes.whitespace);
		++flowLevel_;
		increaseIndent(Yes.flow);
		state_ = &expectFlowMappingKey!(Yes.first);
		return true;
	}

	///Handle a key in a flow mapping.
	private bool expectFlowMappingKey(Flag!"first" first)() {
		if (event_.id == EventID.MappingEnd) {
			indent_ = popIndent();
			--flowLevel_;
			static if (!first)
				if (canonical_) {
					writeIndicator(",", No.needWhitespace);
					writeIndent();
				}
			writeIndicator("}", No.needWhitespace);
			state_ = popState();
			return true;
		}

		static if (!first) {
			writeIndicator(",", No.needWhitespace);
		}
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		if (!canonical_ && checkSimpleKey()) {
			states_ ~= &expectFlowMappingSimpleValue;
			return expectMappingNode(true);
		}

		writeIndicator("?", Yes.needWhitespace);
		states_ ~= &expectFlowMappingValue;
		return expectMappingNode();
	}

	///Handle a simple value in a flow mapping.
	private bool expectFlowMappingSimpleValue() {
		writeIndicator(":", No.needWhitespace);
		states_ ~= &expectFlowMappingKey!(No.first);
		return expectMappingNode();
	}

	///Handle a complex value in a flow mapping.
	private bool expectFlowMappingValue() {
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		writeIndicator(":", Yes.needWhitespace);
		states_ ~= &expectFlowMappingKey!(No.first);
		return expectMappingNode();
	}

	//Block sequence handlers.

	///Handle a block sequence.
	private bool expectBlockSequence() {
		const indentless = (context_ == Context.MappingNoSimpleKey || context_ == Context.MappingSimpleKey) && !indentation_;
		increaseIndent(No.flow, indentless);
		state_ = &expectBlockSequenceItem!(Yes.first);
		return true;
	}

	///Handle a block sequence item.
	private bool expectBlockSequenceItem(Flag!"first" first)() {
		static if (!first)
			if (event_.id == EventID.SequenceEnd) {
				indent_ = popIndent();
				state_ = popState();
				return true;
			}

		writeIndent();
		writeIndicator("-", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockSequenceItem!(No.first);
		return expectSequenceNode();
	}

	//Block mapping handlers.

	///Handle a block mapping.
	private bool expectBlockMapping() {
		increaseIndent(No.flow);
		state_ = &expectBlockMappingKey!(Yes.first);
		return true;
	}

	///Handle a key in a block mapping.
	private bool expectBlockMappingKey(Flag!"first" first)() {
		static if (!first)
			if (event_.id == EventID.MappingEnd) {
				indent_ = popIndent();
				state_ = popState();
				return true;
			}

		writeIndent();
		if (checkSimpleKey()) {
			states_ ~= &expectBlockMappingSimpleValue;
			return expectMappingNode(true);
		}

		writeIndicator("?", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockMappingValue;
		return expectMappingNode();
	}

	///Handle a simple value in a block mapping.
	private bool expectBlockMappingSimpleValue() {
		writeIndicator(":", No.needWhitespace);
		states_ ~= &expectBlockMappingKey!(No.first);
		return expectMappingNode();
	}

	///Handle a complex value in a block mapping.
	private bool expectBlockMappingValue() {
		writeIndent();
		writeIndicator(":", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockMappingKey!(No.first);
		return expectMappingNode();
	}

	//Checkers.

	///Check if an empty sequence is next.
	private bool checkEmptySequence() const nothrow {
		return event_.id == EventID.SequenceStart && events_.length > 0 && events_.peek().id == EventID.SequenceEnd;
	}

	///Check if an empty mapping is next.
	private bool checkEmptyMapping() const nothrow {
		return event_.id == EventID.MappingStart && events_.length > 0 && events_.peek().id == EventID.MappingEnd;
	}

	///Check if an empty document is next.
	private bool checkEmptyDocument() const nothrow {
		if (event_.id != EventID.DocumentStart || events_.length == 0) {
			return false;
		}

		const event = events_.peek();
		const emptyScalar = event.id == EventID.Scalar && event.anchor.isNull() && event.tag.isNull() && event.implicit && event.value == "";
		return emptyScalar;
	}

	///Check if a simple key is next.
	private bool checkSimpleKey() nothrow {
		uint length = 0;
		const id = event_.id;
		const scalar = id == EventID.Scalar;
		const collectionStart = id == EventID.MappingStart || id == EventID.SequenceStart;

		if ((id == EventID.Alias || scalar || collectionStart) && !event_.anchor.isNull()) {
			if (preparedAnchor_ is null) {
				preparedAnchor_ = event_.anchor;
			}
			length += preparedAnchor_.length;
		}

		if ((scalar || collectionStart) && !event_.tag.isNull()) {
			if (preparedTag_ is null) {
				preparedTag_ = event_.tag.withDirectives(tagDirectives_);
			}
			length += preparedTag_.length;
		}

		if (scalar) {
			if (analysis_.flags & ScalarFlags.isNull) {
				analysis_ = analyzeScalar(event_.value);
			}
			length += analysis_.scalar.length;
		}

		if (length >= 128) {
			return false;
		}

		return id == EventID.Alias || (scalar && !(analysis_.flags & ScalarFlags.empty) && !(analysis_.flags & ScalarFlags.multiline)) || checkEmptySequence() || checkEmptyMapping();
	}

	///Process and write a scalar.
	private bool processScalar() {
		if (analysis_.flags & ScalarFlags.isNull) {
			analysis_ = analyzeScalar(event_.value);
		}
		if (style_ == ScalarStyle.Invalid) {
			style_ = chooseScalarStyle();
		}

		//if(analysis_.flags.multiline && (context_ != Context.MappingSimpleKey) &&
		//   ([ScalarStyle.Invalid, ScalarStyle.Plain, ScalarStyle.SingleQuoted, ScalarStyle.DoubleQuoted)
		//    .canFind(style_))
		//{
		//    writeIndent();
		//}
		try {
			with (ScalarWriter(analysis_.scalar, context_ != Context.MappingSimpleKey)) final switch (style_) {
				case ScalarStyle.Invalid:
					assert(false);
				case ScalarStyle.DoubleQuoted:
					writeDoubleQuoted(this);
					break;
				case ScalarStyle.SingleQuoted:
					writeSingleQuoted(this);
					break;
				case ScalarStyle.Folded:
					writeFolded(this);
					break;
				case ScalarStyle.Literal:
					writeLiteral(this);
					break;
				case ScalarStyle.Plain:
					writePlain(this);
					break;
			}
		} catch (Exception) {
			return false;
		}
		analysis_.flags |= ScalarFlags.isNull;
		style_ = ScalarStyle.Invalid;
		return true;
	}

	///Process and write an anchor/alias.
	private void processAnchor(const string indicator) {
		if (event_.anchor.isNull()) {
			preparedAnchor_ = null;
			return;
		}
		if (preparedAnchor_ is null) {
			preparedAnchor_ = event_.anchor;
		}
		if (preparedAnchor_ !is null && preparedAnchor_ != "") {
			writeIndicator(indicator, Yes.needWhitespace);
			put(stream_, preparedAnchor_);
		}
		preparedAnchor_ = null;
	}

	///Process and write a tag.
	private void processTag() {
		Tag tag = event_.tag;
		enum defaultTag = Tag("!");

		if (event_.id == EventID.Scalar) {
			if (style_ == ScalarStyle.Invalid) {
				style_ = chooseScalarStyle();
			}
			if ((!canonical_ || tag.isNull()) && (style_ == ScalarStyle.Plain ? event_.implicit : event_.implicit_2)) {
				preparedTag_ = null;
				return;
			}
			if (event_.implicit && tag.isNull()) {
				tag = defaultTag;
				preparedTag_ = null;
			}
		} else if ((!canonical_ || tag.isNull()) && event_.implicit) {
			preparedTag_ = null;
			return;
		}

		if (preparedTag_ is null) {
			preparedTag_ = tag.withDirectives(tagDirectives_);
		}
		if (preparedTag_ !is null && preparedTag_ != "") {
			writeIndicator(preparedTag_, Yes.needWhitespace);
		}
		preparedTag_ = null;
	}

	///Determine style to write the current scalar in.
	private ScalarStyle chooseScalarStyle() nothrow {
		if (analysis_.flags & ScalarFlags.isNull) {
			analysis_ = analyzeScalar(event_.value);
		}

		const style = event_.scalarStyle;
		const invalidOrPlain = style == ScalarStyle.Invalid || style == ScalarStyle.Plain;
		const block = style == ScalarStyle.Literal || style == ScalarStyle.Folded;
		const singleQuoted = style == ScalarStyle.SingleQuoted;
		const doubleQuoted = style == ScalarStyle.DoubleQuoted;

		const allowPlain = flowLevel_ > 0 ? analysis_.flags & ScalarFlags.allowFlowPlain : analysis_.flags & ScalarFlags.allowBlockPlain;
		//simple empty or multiline scalars can't be written in plain style
		const simpleNonPlain = (context_ == Context.MappingSimpleKey) && (analysis_.flags & ScalarFlags.empty || analysis_.flags & ScalarFlags.multiline);

		if (doubleQuoted || canonical_) {
			return ScalarStyle.DoubleQuoted;
		}

		if (invalidOrPlain && event_.implicit && !simpleNonPlain && allowPlain) {
			return ScalarStyle.Plain;
		}

		if (block && flowLevel_ == 0 && context_ != Context.MappingSimpleKey && analysis_.flags & ScalarFlags.allowBlock) {
			return style;
		}

		if ((invalidOrPlain || singleQuoted) && analysis_.flags & ScalarFlags.allowSingleQuoted && !(context_ == Context.MappingSimpleKey && analysis_.flags & ScalarFlags.multiline)) {
			return ScalarStyle.SingleQuoted;
		}

		return ScalarStyle.DoubleQuoted;
	}

	///Analyze specifed scalar and return the analysis result.
	private static ScalarAnalysis analyzeScalar(string scalar) nothrow {
		ScalarAnalysis analysis;
		analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.isNull);
		analysis.scalar = scalar;

		//Empty scalar is a special case.
		if (scalar is null || scalar == "") {
			analysis.flags = ScalarFlags.empty | ScalarFlags.allowBlockPlain | ScalarFlags.allowSingleQuoted | ScalarFlags.allowDoubleQuoted;
			return analysis;
		}

		//Indicators and special characters (All false by default).
		bool blockIndicators, flowIndicators, lineBreaks, specialCharacters;

		//Important whitespace combinations (All false by default).
		bool leadingSpace, leadingBreak, trailingSpace, trailingBreak, breakSpace, spaceBreak;

		//Check document indicators.
		if (scalar.byDchar.startsWith("---"d, "..."d)) {
			blockIndicators = flowIndicators = true;
		}

		//First character or preceded by a whitespace.
		bool preceededByWhitespace = true;

		//Last character or followed by a whitespace.
		bool followedByWhitespace = scalar.length == 1 || scalar[1].among(newLines, '\n', '\0', '\t', ' ');

		//The previous character is a space/break (false by default).
		bool previousSpace, previousBreak;

		foreach (index, c; scalar) {
			//Check for indicators.
			if (index == 0) {
				//Leading indicators are special characters.
				if (c.among(specialCharSeq)) {
					flowIndicators = blockIndicators = true;
				}
				if (':' == c || '?' == c) {
					flowIndicators = true;
					if (followedByWhitespace) {
						blockIndicators = true;
					}
				}
				if (c == '-' && followedByWhitespace) {
					flowIndicators = blockIndicators = true;
				}
			} else {
				//Some indicators cannot appear within a scalar as well.
				if (c.among(flowIndicatorSeq)) {
					flowIndicators = true;
				}
				if (c == ':') {
					flowIndicators = true;
					if (followedByWhitespace) {
						blockIndicators = true;
					}
				}
				if (c == '#' && preceededByWhitespace) {
					flowIndicators = blockIndicators = true;
				}
			}

			//Check for line breaks, special, and unicode characters.
			if (!(c == '\n' || (c >= '\x20' && c <= '\x7E')) && !((c == '\u0085' || (c >= '\xA0' && c <= '\uD7FF') || (c >= '\uE000' && c <= '\uFFFD')) && c != '\uFEFF')) {
				specialCharacters = true;
			}

			//Detect important whitespace combinations.
			if (c == ' ') {
				if (index == 0) {
					leadingSpace = true;
				}
				if (index + 1 == scalar.length) {
					trailingSpace = true;
				}
				if (previousBreak) {
					breakSpace = true;
				}
				previousSpace = true;
				previousBreak = false;
			} else if (c.among(newLines)) {
				lineBreaks = true;
				if (index == 0) {
					leadingBreak = true;
				}
				if (index + 1 == scalar.length) {
					trailingBreak = true;
				}
				if (previousSpace) {
					spaceBreak = true;
				}
				previousSpace = false;
				previousBreak = true;
			} else {
				previousSpace = previousBreak = false;
			}

			//Prepare for the next character.
			preceededByWhitespace = !!c.among(newLines, '\r', '\0', ' ');
			followedByWhitespace = index + 2 >= scalar.length || scalar[index + 2].among(newLines, '\r', '\0', ' ');
		}

		//Let's decide what styles are allowed.
		analysis.flags = ScalarFlags.allowFlowPlain | ScalarFlags.allowBlockPlain | ScalarFlags.allowSingleQuoted | ScalarFlags.allowDoubleQuoted | ScalarFlags.allowBlock;

		//Leading and trailing whitespaces are bad for plain scalars.
		if (leadingSpace || leadingBreak || trailingSpace || trailingBreak) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowFlowPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlockPlain);
		}

		//We do not permit trailing spaces for block scalars.
		if (trailingSpace) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlock);
		}

		//Spaces at the beginning of a new line are only acceptable for block
		//scalars.
		if (breakSpace) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowFlowPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlockPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowSingleQuoted);
		}

		//Spaces followed by breaks, as well as special character are only
		//allowed for double quoted scalars.
		if (spaceBreak || specialCharacters) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowFlowPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlockPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowSingleQuoted);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlock);
		}

		//Although the plain scalar writer supports breaks, we never emit
		//multiline plain scalars.
		if (lineBreaks) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowFlowPlain);
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlockPlain);
		}

		//Flow indicators are forbidden for flow plain scalars.
		if (flowIndicators) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowFlowPlain);
		}

		//Block indicators are forbidden for block plain scalars.
		if (blockIndicators) {
			analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.allowBlockPlain);
		}

		analysis.flags &= ~BitFlags!ScalarFlags(ScalarFlags.empty);
		if (lineBreaks)
			analysis.flags |= ScalarFlags.multiline;
		else
			analysis.flags &= BitFlags!ScalarFlags(ScalarFlags.multiline);

		return analysis;
	}

	//Writers.

	///Write an indicator (e.g. ":", "[", ">", etc.).
	private void writeIndicator(const string indicator, const Flag!"needWhitespace" needWhitespace, const Flag!"whitespace" whitespace = No.whitespace, const Flag!"indentation" indentation = No.indentation) {
		const bool prefixSpace = !whitespace_ && needWhitespace;
		whitespace_ = whitespace;
		indentation_ = indentation_ && indentation;
		openEnded_ = false;
		column_ += indicator.length;
		if (prefixSpace) {
			++column_;
			put(stream_, " ");
		}
		put(stream_, indicator);
	}

	///Write indentation.
	private void writeIndent() {
		const indent = indent_ == -1 ? 0 : indent_;

		if (!indentation_ || column_ > indent || (column_ == indent && !whitespace_)) {
			writeLineBreak();
		}
		if (column_ < indent) {
			whitespace_ = true;

			put(stream_, " ".repeat(indent - column_));
			column_ = indent;
		}
	}

	///Start new line.
	private void writeLineBreak(const string data = null) {
		whitespace_ = indentation_ = true;
		++line_;
		column_ = 0;
		put(stream_, data is null ? lineBreak(bestLineBreak_) : data);
	}

	///Write a YAML version directive.
	private void writeVersionDirective(immutable YAMLVersion versionText) {
		put(stream_, "%YAML ");
		put(stream_, cast(string)versionText);
		writeLineBreak();
	}

	///Write a tag directive.
	private void writeTagDirective(const TagDirective directive) {
		put(stream_, "%TAG ");
		put(stream_, directive.handle.data);
		put(stream_, " ");
		put(stream_, directive.prefix.data);
		writeLineBreak();
	}
}

///RAII struct used to write out scalar values.
private struct ScalarWriter {
	///Used as "null" UTF-32 character.
	private static immutable dcharNone = dchar.max;

	///UTF-8 encoded text of the scalar to write.
	private string text_;

	///Can we split the scalar into multiple lines?
	private bool split_;
	///Are we currently going over spaces in the text?
	private bool spaces_;
	///Are we currently going over line breaks in the text?
	private bool breaks_;

	///Start and end byte of the text range we're currently working with.
	private size_t startByte_, endByte_;
	///End byte of the text range including the currently processed character.
	private size_t nextEndByte_;
	///Start and end character of the text range we're currently working with.
	private long startChar_, endChar_;

	///Construct a ScalarWriter using emitter to output text.
	public this(string text, const bool split = true) {
		text_ = text;
		split_ = split;
	}

	///Write text as single quoted scalar.
	public void writeSingleQuoted(T)(ref Emitter!T emitter) {
		emitter.writeIndicator("\'", Yes.needWhitespace);
		spaces_ = breaks_ = false;
		resetTextPosition();
		long startChar, endChar;
		do {
			endChar++;
			const dchar c = nextChar();
			if (spaces_) {
				if (c != ' ' && tooWide(emitter) && split_ && startByte_ != 0 && endByte_ != text_.length) {
					writeIndent(emitter, Flag!"ResetSpace".no);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
				}
			} else if (breaks_) {
				if (!c.among(newLines)) {
					writeStartLineBreak(emitter);
					writeLineBreaks(emitter);
					emitter.writeIndent();
				}
			} else if (c.among(newLines, ' ', '\'', dcharNone) && startChar < endChar) {
				writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
			}
			if (c == '\'') {
				emitter.column_ += 2;
				emitter.writeString("\'\'");
				startByte_ = endByte_ + 1;
				startChar = endChar + 1;
			}
			updateBreaks(c, Flag!"UpdateSpaces".yes);
		}
		while (endByte_ < text_.length);

		emitter.writeIndicator("\'", No.needWhitespace);
	}

	///Write text as double quoted scalar.
	public void writeDoubleQuoted(T)(ref Emitter!T emitter) {
		long startChar, endChar;
		resetTextPosition();
		emitter.writeIndicator("\"", Yes.needWhitespace);
		do {
			endChar++;
			const dchar c = nextChar();
			//handle special characters
			if (c.among(dcharNone, '"', '\\', unicodeNewLines, '\uFEFF') || !((c >= '\x20' && c <= '\x7E') || ((c >= '\xA0' && c <= '\uD7FF') || (c >= '\uE000' && c <= '\uFFFD')))) {
				if (startChar < endChar) {
					writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
				}
				if (c != dcharNone) {
					auto appender = appender!string();
					if ((c in wyaml.escapes.toEscapes) !is null) {
						put(appender, '\\');
						put(appender, wyaml.escapes.toEscapes[c]);
					} else {
						//Write an escaped Unicode character.
						const format = c <= 0xFF ? "\\x%02X" : c <= 0xFFFF ? "\\u%04X" : "\\U%08X";
						formattedWrite(appender, format, cast(uint) c);
					}

					emitter.column_ += appender.data.length;
					emitter.writeString(appender.data);
					startChar = endChar + 1;
					startByte_ = nextEndByte_;
				}
			}
			if ((endByte_ > 0 && endByte_ < text_.length - strideBack(text_, text_.length)) && (c == ' ' || startChar >= endChar) && (emitter.column_ + endChar - startChar > emitter.bestWidth_) && split_) {
				//text_[2:1] is ok in Python but not in D, so we have to use min()
				emitter.writeString(text_[min(startByte_, endByte_) .. endByte_]);
				emitter.writeString("\\");
				emitter.column_ += startChar_ - endChar_ + 1;
				startChar_ = max(startChar_, endChar_);
				startByte_ = max(startByte_, endByte_);

				writeIndent(emitter, Flag!"ResetSpace".yes);
				if (charAtStart() == ' ') {
					emitter.writeString("\\");
					++emitter.column_;
				}
			}
		}
		while (endByte_ < text_.length);
		emitter.writeIndicator("\"", No.needWhitespace);
	}

	///Write text as folded block scalar.
	public void writeFolded(T)(ref Emitter!T emitter) {
		long startChar, endChar;
		initBlock(emitter, '>');
		bool leadingSpace = true;
		spaces_ = false;
		breaks_ = true;
		resetTextPosition();

		do {
			endChar++;
			const dchar c = nextChar();
			if (breaks_) {
				if (!c.among(newLines)) {
					if (!leadingSpace && c != dcharNone && c != ' ') {
						writeStartLineBreak(emitter);
					}
					leadingSpace = (c == ' ');
					writeLineBreaks(emitter);
					if (c != dcharNone) {
						emitter.writeIndent();
					}
				}
			} else if (spaces_) {
				if (c != ' ' && tooWide(emitter)) {
					writeIndent(emitter, Flag!"ResetSpace".no);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
				}
			} else if (c.among(newLines, dcharNone, ' ')) {
				writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
				if (c == dcharNone) {
					emitter.writeLineBreak();
				}
			}
			updateBreaks(c, Flag!"UpdateSpaces".yes);
		}
		while (endByte_ < text_.length);
	}

	///Write text as literal block scalar.
	public void writeLiteral(T)(ref Emitter!T emitter) {
		initBlock(emitter, '|');
		breaks_ = true;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (breaks_) {
				if (!c.among(newLines)) {
					writeLineBreaks(emitter);
					if (c != dcharNone) {
						emitter.writeIndent();
					}
				}
			} else if (c.among(dcharNone, newLines)) {
				writeCurrentRange(emitter, Flag!"UpdateColumn".no);
				if (c == dcharNone) {
					emitter.writeLineBreak();
				}
			}
			updateBreaks(c, Flag!"UpdateSpaces".no);
		}
		while (endByte_ < text_.length);
	}

	///Write text as plain scalar.
	public void writePlain(T)(ref Emitter!T emitter) {
		if (emitter.context_ == Emitter!T.Context.Root) {
			emitter.openEnded_ = true;
		}
		if (text_ == "") {
			return;
		}
		if (!emitter.whitespace_) {
			++emitter.column_;
			emitter.writeString(" ");
		}
		emitter.whitespace_ = emitter.indentation_ = false;
		spaces_ = breaks_ = false;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (spaces_) {
				if (c != ' ' && tooWide(emitter) && split_) {
					writeIndent(emitter, Flag!"ResetSpace".yes);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
				}
			} else if (breaks_) {
				if (!c.among(newLines)) {
					writeStartLineBreak(emitter);
					writeLineBreaks(emitter);
					writeIndent(emitter, Flag!"ResetSpace".yes);
				}
			} else if (c.among(dcharNone, newLines, ' ')) {
				writeCurrentRange(emitter, Flag!"UpdateColumn".yes);
			}
			updateBreaks(c, Flag!"UpdateSpaces".yes);
		}
		while (endByte_ < text_.length);
	}

	///Get next character and move end of the text range to it.
	private dchar nextChar() {
		++endChar_;
		endByte_ = nextEndByte_;
		if (endByte_ >= text_.length) {
			return dcharNone;
		}
		return decode(text_, nextEndByte_);
	}

	///Get character at start of the text range.
	private dchar charAtStart() const {
		return text_[startByte_];
	}

	///Is the current line too wide?
	private bool tooWide(T)(ref Emitter!T emitter) const {
		return startChar_ + 1 == endChar_ && emitter.column_ > emitter.bestWidth_;
	}

	///Determine hints (indicators) for block scalar.
	private size_t determineBlockHints(char[] hints, uint bestIndent) const {
		size_t hintsIdx = 0;
		if (text_.length == 0) {
			return hintsIdx;
		}

		dchar lastChar(const string str, ref size_t end) {
			size_t idx = end = end - strideBack(str, end);
			return decode(text_, idx);
		}

		size_t end = text_.length;
		const last = lastChar(text_, end);
		const secondLast = end > 0 ? lastChar(text_, end) : 0;

		if (text_[0].among(newLines, ' ')) {
			hints[hintsIdx++] = cast(char)('0' + bestIndent);
		}
		if (!last.among(newLines)) {
			hints[hintsIdx++] = '-';
		} else if (std.utf.count(text_) == 1 || secondLast.among(newLines)) {
			hints[hintsIdx++] = '+';
		}
		return hintsIdx;
	}

	///Initialize for block scalar writing with specified indicator.
	private void initBlock(T)(ref Emitter!T emitter, const char indicator) {
		char[4] hints;
		hints[0] = indicator;
		const hintsLength = 1 + determineBlockHints(hints[1 .. $], emitter.bestIndent_);
		emitter.writeIndicator(cast(string) hints[0 .. hintsLength], Yes.needWhitespace);
		if (hints.length > 0 && hints[$ - 1] == '+') {
			emitter.openEnded_ = true;
		}
		emitter.writeLineBreak();
	}

	///Write out the current text range.
	private void writeCurrentRange(T)(ref Emitter!T emitter, const Flag!"UpdateColumn" updateColumn) {
		emitter.writeString(text_[startByte_ .. endByte_]);
		if (updateColumn) {
			emitter.column_ += endChar_ - startChar_;
		}
		updateRangeStart();
	}

	///Write line breaks in the text range.
	private void writeLineBreaks(T)(ref Emitter!T emitter) {
		foreach (const dchar br; text_[startByte_ .. endByte_]) {
			if (br == '\n') {
				emitter.writeLineBreak();
			} else {
				char[] brString;
				brString.reserve(4);
				encode(brString, br);
				emitter.writeLineBreak(cast(string) brString);
			}
		}
		updateRangeStart();
	}

	///Write line break if start of the text range is a newline.
	private void writeStartLineBreak(T)(ref Emitter!T emitter) {
		if (charAtStart == '\n') {
			emitter.writeLineBreak();
		}
	}

	///Write indentation, optionally resetting whitespace/indentation flags.
	private void writeIndent(T)(ref Emitter!T emitter, const Flag!"ResetSpace" resetSpace) {
		emitter.writeIndent();
		if (resetSpace) {
			emitter.whitespace_ = emitter.indentation_ = false;
		}
	}

	///Move start of text range to its end.
	private void updateRangeStart() {
		startByte_ = endByte_;
		startChar_ = endChar_;
	}

	///Update the line breaks_ flag, optionally updating the spaces_ flag.
	private void updateBreaks(in dchar c, const Flag!"UpdateSpaces" updateSpaces) {
		if (c == dcharNone) {
			return;
		}
		breaks_ = !!c.among(newLines);
		if (updateSpaces) {
			spaces_ = c == ' ';
		}
	}

	///Move to the beginning of text.
	private void resetTextPosition() {
		startByte_ = endByte_ = nextEndByte_ = 0;
		startChar_ = endChar_ = -1;
	}
}

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
package alias invalidTagChars = AliasSeq!('-', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '~', '*', '\'', '(', ')', '[', ']');

//Emits YAML events into a file/stream.
package struct Emitter(T) {
	private alias TagDirective = wyaml.tagdirective.TagDirective;

	///Default tag handle shortcuts and replacements.
	private static TagDirective[] defaultTagDirectives_ = [TagDirective("!", "!"), TagDirective("!!", "tag:yaml.org,2002:")];

	///Stream to write to.
	private T stream_;

	///Stack of states.
	private void delegate()[] states_;
	///Current state.
	private void delegate() state_;

	///Event queue.
	private Queue!Event events_;
	///Event we're currently emitting.
	private Event event_;

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
			event_ = events_.pop();
			state_();
			event_.destroy();
		}
	}

	///Pop and return the newest state in states_.
	private void delegate() popState() {
		enforce(states_.length > 0, new YAMLException("Emitter: Need to pop a state but there are no states left"));
		const result = states_.back;
		states_.popBack();
		return result;
	}

	///Pop and return the newest indent in indents_.
	private int popIndent() {
		enforce(indents_.length > 0, new YAMLException("Emitter: Need to pop an indent level but there are no indent levels left"));
		const result = indents_.back;
		indents_.popBack();
		return result;
	}

	///Write a string to the file/stream.
	private void writeString(const string str) {
		stream_.put(str);
	}

	///In some cases, we wait for a few next events before emitting.
	private bool needMoreEvents() {
		if (events_.length == 0) {
			return true;
		}

		const event = events_.peek();
		if (event.id == EventID.DocumentStart) {
			return needEvents(1);
		}
		if (event.id == EventID.SequenceStart) {
			return needEvents(2);
		}
		if (event.id == EventID.MappingStart) {
			return needEvents(3);
		}

		return false;
	}

	///Determines if we need specified number of more events.
	private bool needEvents(in uint count) {
		int level = 0;
		foreach (event; events_) {
			if (event.id.among(EventID.DocumentStart, EventID.SequenceStart, EventID.MappingStart)) {
				++level;
			} else if (event.id.among(EventID.DocumentEnd, EventID.SequenceEnd, EventID.MappingEnd)) {
				--level;
			} else if (event.id == EventID.StreamStart) {
				level = -1;
			}

			if (level < 0) {
				return false;
			}
		}

		return events_.length < (count + 1);
	}

	///Increase indentation level.
	private void increaseIndent(const Flag!"flow" flow = No.flow, const bool indentless = false) {
		indents_ ~= indent_;
		if (indent_ == -1) {
			indent_ = flow ? bestIndent_ : 0;
		} else if (!indentless) {
			indent_ += bestIndent_;
		}
	}

	///Determines if the type of current event is as specified. Throws if no event.
	private bool eventTypeIs(in EventID id) const {
		enforce(!event_.isNull, new EmitterException("Expected an event, but no event is available."));
		return event_.id == id;
	}

	//States.

	//Stream handlers.

	///Handle start of a file/stream.
	private void expectStreamStart() {
		enforce(eventTypeIs(EventID.StreamStart), new EmitterException("Expected StreamStart, but got " ~ event_.idString));

		writeStreamStart();
		state_ = &expectDocumentStart!(Yes.first);
	}

	///Expect nothing, throwing if we still have something.
	private void expectNothing() const {
		throw new EmitterException("Expected nothing, but got " ~ event_.idString);
	}

	//Document handlers.

	///Handle start of a document.
	private void expectDocumentStart(Flag!"first" first)() {
		enforce(eventTypeIs(EventID.DocumentStart) || eventTypeIs(EventID.StreamEnd), new EmitterException("Expected DocumentStart or StreamEnd, but got " ~ event_.idString));

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
				tagDirectives_ = event_.tagDirectives;
				sort!"icmp(a.handle, b.handle) < 0"(tagDirectives_);

				foreach (ref pair; tagDirectives_) {
					writeTagDirective(prepareTagHandle(pair.handle), prepareTagPrefix(pair.prefix));
				}
			}

			bool eq(ref TagDirective a, ref TagDirective b) {
				return a.handle == b.handle;
			}
			//Add any default tag directives that have not been overriden.
			foreach (ref def; defaultTagDirectives_) {
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
			writeStreamEnd();
			state_ = &expectNothing;
		}
	}

	///Handle end of a document.
	private void expectDocumentEnd() {
		enforce(eventTypeIs(EventID.DocumentEnd), new EmitterException("Expected DocumentEnd, but got " ~ event_.idString));

		writeIndent();
		if (event_.explicitDocument) {
			writeIndicator("...", Yes.needWhitespace);
			writeIndent();
		}
		state_ = &expectDocumentStart!(No.first);
	}

	///Handle the root node of a document.
	private void expectRootNode() {
		states_ ~= &expectDocumentEnd;
		expectNode(Context.Root);
	}

	///Handle a mapping node.
	//
	//Params: simpleKey = Are we in a simple key?
	private void expectMappingNode(const bool simpleKey = false) {
		expectNode(simpleKey ? Context.MappingSimpleKey : Context.MappingNoSimpleKey);
	}

	///Handle a sequence node.
	private void expectSequenceNode() {
		expectNode(Context.Sequence);
	}

	///Handle a new node. Context specifies where in the document we are.
	private void expectNode(const Context context) {
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
				throw new EmitterException("Expected Alias, Scalar, SequenceStart or MappingStart, but got: " ~ event_.idString);
		}
	}
	///Handle an alias.
	private void expectAlias() {
		enforce(!event_.anchor.isNull(), new EmitterException("Anchor is not specified for alias"));
		processAnchor("*");
		state_ = popState();
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
	private void expectFlowSequenceItem(Flag!"first" first)() {
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
			return;
		}
		static if (!first) {
			writeIndicator(",", No.needWhitespace);
		}
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		states_ ~= &expectFlowSequenceItem!(No.first);
		expectSequenceNode();
	}

	//Flow mapping handlers.

	///Handle a flow mapping.
	private void expectFlowMapping() {
		writeIndicator("{", Yes.needWhitespace, Yes.whitespace);
		++flowLevel_;
		increaseIndent(Yes.flow);
		state_ = &expectFlowMappingKey!(Yes.first);
	}

	///Handle a key in a flow mapping.
	private void expectFlowMappingKey(Flag!"first" first)() {
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
			return;
		}

		static if (!first) {
			writeIndicator(",", No.needWhitespace);
		}
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		if (!canonical_ && checkSimpleKey()) {
			states_ ~= &expectFlowMappingSimpleValue;
			expectMappingNode(true);
			return;
		}

		writeIndicator("?", Yes.needWhitespace);
		states_ ~= &expectFlowMappingValue;
		expectMappingNode();
	}

	///Handle a simple value in a flow mapping.
	private void expectFlowMappingSimpleValue() {
		writeIndicator(":", No.needWhitespace);
		states_ ~= &expectFlowMappingKey!(No.first);
		expectMappingNode();
	}

	///Handle a complex value in a flow mapping.
	private void expectFlowMappingValue() {
		if (canonical_ || column_ > bestWidth_) {
			writeIndent();
		}
		writeIndicator(":", Yes.needWhitespace);
		states_ ~= &expectFlowMappingKey!(No.first);
		expectMappingNode();
	}

	//Block sequence handlers.

	///Handle a block sequence.
	private void expectBlockSequence() {
		const indentless = (context_ == Context.MappingNoSimpleKey || context_ == Context.MappingSimpleKey) && !indentation_;
		increaseIndent(No.flow, indentless);
		state_ = &expectBlockSequenceItem!(Yes.first);
	}

	///Handle a block sequence item.
	private void expectBlockSequenceItem(Flag!"first" first)() {
		static if (!first)
			if (event_.id == EventID.SequenceEnd) {
				indent_ = popIndent();
				state_ = popState();
				return;
			}

		writeIndent();
		writeIndicator("-", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockSequenceItem!(No.first);
		expectSequenceNode();
	}

	//Block mapping handlers.

	///Handle a block mapping.
	private void expectBlockMapping() {
		increaseIndent(No.flow);
		state_ = &expectBlockMappingKey!(Yes.first);
	}

	///Handle a key in a block mapping.
	private void expectBlockMappingKey(Flag!"first" first)() {
		static if (!first)
			if (event_.id == EventID.MappingEnd) {
				indent_ = popIndent();
				state_ = popState();
				return;
			}

		writeIndent();
		if (checkSimpleKey()) {
			states_ ~= &expectBlockMappingSimpleValue;
			expectMappingNode(true);
			return;
		}

		writeIndicator("?", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockMappingValue;
		expectMappingNode();
	}

	///Handle a simple value in a block mapping.
	private void expectBlockMappingSimpleValue() {
		writeIndicator(":", No.needWhitespace);
		states_ ~= &expectBlockMappingKey!(No.first);
		expectMappingNode();
	}

	///Handle a complex value in a block mapping.
	private void expectBlockMappingValue() {
		writeIndent();
		writeIndicator(":", Yes.needWhitespace, No.whitespace, Yes.indentation);
		states_ ~= &expectBlockMappingKey!(No.first);
		expectMappingNode();
	}

	//Checkers.

	///Check if an empty sequence is next.
	private bool checkEmptySequence() const {
		return event_.id == EventID.SequenceStart && events_.length > 0 && events_.peek().id == EventID.SequenceEnd;
	}

	///Check if an empty mapping is next.
	private bool checkEmptyMapping() const {
		return event_.id == EventID.MappingStart && events_.length > 0 && events_.peek().id == EventID.MappingEnd;
	}

	///Check if an empty document is next.
	private bool checkEmptyDocument() const {
		if (event_.id != EventID.DocumentStart || events_.length == 0) {
			return false;
		}

		const event = events_.peek();
		const emptyScalar = event.id == EventID.Scalar && event.anchor.isNull() && event.tag.isNull() && event.implicit && event.value == "";
		return emptyScalar;
	}

	///Check if a simple key is next.
	private bool checkSimpleKey() {
		uint length = 0;
		const id = event_.id;
		const scalar = id == EventID.Scalar;
		const collectionStart = id == EventID.MappingStart || id == EventID.SequenceStart;

		if ((id == EventID.Alias || scalar || collectionStart) && !event_.anchor.isNull()) {
			if (preparedAnchor_ is null) {
				preparedAnchor_ = prepareAnchor(event_.anchor);
			}
			length += preparedAnchor_.length;
		}

		if ((scalar || collectionStart) && !event_.tag.isNull()) {
			if (preparedTag_ is null) {
				preparedTag_ = prepareTag(event_.tag);
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
	private void processScalar() {
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
		with (ScalarWriter!T(this, analysis_.scalar, context_ != Context.MappingSimpleKey)) final switch (style_) {
			case ScalarStyle.Invalid:
				assert(false);
			case ScalarStyle.DoubleQuoted:
				writeDoubleQuoted();
				break;
			case ScalarStyle.SingleQuoted:
				writeSingleQuoted();
				break;
			case ScalarStyle.Folded:
				writeFolded();
				break;
			case ScalarStyle.Literal:
				writeLiteral();
				break;
			case ScalarStyle.Plain:
				writePlain();
				break;
		}
		analysis_.flags |= ScalarFlags.isNull;
		style_ = ScalarStyle.Invalid;
	}

	///Process and write an anchor/alias.
	private void processAnchor(const string indicator) {
		if (event_.anchor.isNull()) {
			preparedAnchor_ = null;
			return;
		}
		if (preparedAnchor_ is null) {
			preparedAnchor_ = prepareAnchor(event_.anchor);
		}
		if (preparedAnchor_ !is null && preparedAnchor_ != "") {
			writeIndicator(indicator, Yes.needWhitespace);
			stream_.put(preparedAnchor_);
		}
		preparedAnchor_ = null;
	}

	///Process and write a tag.
	private void processTag() {
		Tag tag = event_.tag;

		if (event_.id == EventID.Scalar) {
			if (style_ == ScalarStyle.Invalid) {
				style_ = chooseScalarStyle();
			}
			if ((!canonical_ || tag.isNull()) && (style_ == ScalarStyle.Plain ? event_.implicit : event_.implicit_2)) {
				preparedTag_ = null;
				return;
			}
			if (event_.implicit && tag.isNull()) {
				tag = Tag("!");
				preparedTag_ = null;
			}
		} else if ((!canonical_ || tag.isNull()) && event_.implicit) {
			preparedTag_ = null;
			return;
		}

		enforce(!tag.isNull(), new EmitterException("Tag is not specified"));
		if (preparedTag_ is null) {
			preparedTag_ = prepareTag(tag);
		}
		if (preparedTag_ !is null && preparedTag_ != "") {
			writeIndicator(preparedTag_, Yes.needWhitespace);
		}
		preparedTag_ = null;
	}

	///Determine style to write the current scalar in.
	private ScalarStyle chooseScalarStyle() {
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

	///Prepare YAML version string for output.
	private static string prepareVersion(const string YAMLVersion) {
		enforce(YAMLVersion.split(".")[0] == "1", new EmitterException("Unsupported YAML version: " ~ YAMLVersion));
		return YAMLVersion;
	}

	///Encode an Unicode character for tag directive and write it to writer.
	private static void encodeChar(Writer)(ref Writer writer, in dchar c) {
		char[4] data;
		const bytes = encode(data, c);
		//For each byte add string in format %AB , where AB are hex digits of the byte.
		foreach (const char b; data[0 .. bytes]) {
			formattedWrite(writer, "%%%02X", cast(ubyte) b);
		}
	}

	///Prepare tag directive handle for output.
	private static string prepareTagHandle(const string handle) {
		enforce(handle !is null && handle != "", new EmitterException("Tag handle must not be empty"));

		if (handle.length > 1)
			foreach (const dchar c; handle[1 .. $ - 1]) {
				enforce(isAlphaNum(c) || c.among('-', '_'), new EmitterException("Invalid character: " ~ to!string(c) ~ " in tag handle " ~ handle));
			}
		return handle;
	}

	///Prepare tag directive prefix for output.
	private static string prepareTagPrefix(const string prefix) {
		enforce(prefix !is null && prefix != "", new EmitterException("Tag prefix must not be empty"));

		auto appender = appender!string();
		const offset = prefix[0] == '!' ? 1 : 0;
		size_t start = 0;
		size_t end = 0;
		foreach (const size_t i, const dchar c; prefix) {
			const size_t idx = i + offset;
			if (isAlphaNum(c) || c.among(invalidTagChars, '!', '%')) {
				end = idx + 1;
				continue;
			}

			if (start < idx) {
				appender.put(prefix[start .. idx]);
			}
			start = end = idx + 1;

			encodeChar(appender, c);
		}

		end = min(end, prefix.length);
		if (start < end) {
			appender.put(prefix[start .. end]);
		}
		return appender.data;
	}

	///Prepare tag for output.
	private string prepareTag(in Tag tag) {
		enforce(!tag.isNull(), new EmitterException("Tag must not be empty"));

		string tagString = tag.get;
		if (tagString == "!") {
			return tagString;
		}
		string handle = null;
		string suffix = tagString;

		//Sort lexicographically by prefix.
		sort!"icmp(a.prefix, b.prefix) < 0"(tagDirectives_);
		foreach (ref pair; tagDirectives_) {
			auto prefix = pair.prefix;
			if (tagString.startsWith(prefix) && (prefix != "!" || prefix.length < tagString.length)) {
				handle = pair.handle;
				suffix = tagString[prefix.length .. $];
			}
		}

		auto appender = appender!string();
		appender.put(handle !is null && handle != "" ? handle : "!<");
		size_t start = 0;
		size_t end = 0;
		foreach (const dchar c; suffix) {
			if (isAlphaNum(c) || c.among(invalidTagChars) || (c == '!' && handle != "!")) {
				++end;
				continue;
			}
			if (start < end) {
				appender.put(suffix[start .. end]);
			}
			start = end = end + 1;

			encodeChar(appender, c);
		}

		if (start < end) {
			appender.put(suffix[start .. end]);
		}
		if (handle is null || handle == "") {
			appender.put(">");
		}

		return appender.data;
	}

	///Prepare anchor for output.
	private static string prepareAnchor(const Anchor anchor) {
		enforce(!anchor.isNull() && anchor.get != "", new EmitterException("Anchor must not be empty"));
		const str = anchor.get;
		foreach (const dchar c; str) {
			enforce(isAlphaNum(c) || c.among('-', '_'), new EmitterException("Invalid character: " ~ to!string(c) ~ " in anchor: " ~ str));
		}
		return str;
	}

	///Analyze specifed scalar and return the analysis result.
	private static ScalarAnalysis analyzeScalar(string scalar) {
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
		if (scalar.startsWith("---", "...")) {
			blockIndicators = flowIndicators = true;
		}

		//First character or preceded by a whitespace.
		bool preceededByWhitespace = true;

		//Last character or followed by a whitespace.
		bool followedByWhitespace = scalar.length == 1 || scalar[1].among(newLines, '\n', '\0', '\t', ' ');

		//The previous character is a space/break (false by default).
		bool previousSpace, previousBreak;

		foreach (const size_t index, const dchar c; scalar) {
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
			if (c.among(newLines)) {
				lineBreaks = true;
			}
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

	///Start the YAML stream (write the unicode byte order mark).
	private void writeStreamStart() {
		//TODO: add BOM for UTF-16, UTF-32 (0xFEFF)
	}

	///End the YAML stream.
	private void writeStreamEnd() {
	}

	///Write an indicator (e.g. ":", "[", ">", etc.).
	private void writeIndicator(const string indicator, const Flag!"needWhitespace" needWhitespace, const Flag!"whitespace" whitespace = No.whitespace, const Flag!"indentation" indentation = No.indentation) {
		const bool prefixSpace = !whitespace_ && needWhitespace;
		whitespace_ = whitespace;
		indentation_ = indentation_ && indentation;
		openEnded_ = false;
		column_ += indicator.length;
		if (prefixSpace) {
			++column_;
			stream_.put(" ");
		}
		stream_.put(indicator);
	}

	///Write indentation.
	private void writeIndent() {
		const indent = indent_ == -1 ? 0 : indent_;

		if (!indentation_ || column_ > indent || (column_ == indent && !whitespace_)) {
			writeLineBreak();
		}
		if (column_ < indent) {
			whitespace_ = true;

			//Used to avoid allocation of arbitrary length strings.
			static immutable spaces = "    ";
			size_t numSpaces = indent - column_;
			column_ = indent;
			while (numSpaces >= spaces.length) {
				stream_.put(spaces);
				numSpaces -= spaces.length;
			}
			stream_.put(spaces[0 .. numSpaces]);
		}
	}

	///Start new line.
	private void writeLineBreak(const string data = null) {
		whitespace_ = indentation_ = true;
		++line_;
		column_ = 0;
		stream_.put(data is null ? lineBreak(bestLineBreak_) : data);
	}

	///Write a YAML version directive.
	private void writeVersionDirective(const string versionText) {
		stream_.put("%YAML ");
		stream_.put(versionText);
		writeLineBreak();
	}

	///Write a tag directive.
	private void writeTagDirective(const string handle, const string prefix) {
		stream_.put("%TAG ");
		stream_.put(handle);
		stream_.put(" ");
		stream_.put(prefix);
		writeLineBreak();
	}
}

///RAII struct used to write out scalar values.
private struct ScalarWriter(T) {
	invariant() {
		assert(emitter_.bestIndent_ > 0 && emitter_.bestIndent_ < 10, "Emitter bestIndent must be 1 to 9 for one-character indent hint");
	}

	@disable int opCmp(ref Emitter!T) const;
	@disable bool opEquals(ref Emitter!T) const;
	@disable size_t toHash() nothrow @safe;

	///Used as "null" UTF-32 character.
	private static immutable dcharNone = dchar.max;

	///Emitter used to emit the scalar.
	private Emitter!T* emitter_;

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
	public this(ref Emitter!T emitter, string text, const bool split = true) {
		emitter_ = &emitter;
		text_ = text;
		split_ = split;
	}

	///Write text as single quoted scalar.
	public void writeSingleQuoted() {
		emitter_.writeIndicator("\'", Yes.needWhitespace);
		spaces_ = breaks_ = false;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (spaces_) {
				if (c != ' ' && tooWide() && split_ && startByte_ != 0 && endByte_ != text_.length) {
					writeIndent(Flag!"ResetSpace".no);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(Flag!"UpdateColumn".yes);
				}
			} else if (breaks_) {
				if (!c.among(newLines)) {
					writeStartLineBreak();
					writeLineBreaks();
					emitter_.writeIndent();
				}
			} else if (c.among(newLines, ' ', '\'', dcharNone) && startChar_ < endChar_) {
				writeCurrentRange(Flag!"UpdateColumn".yes);
			}
			if (c == '\'') {
				emitter_.column_ += 2;
				emitter_.writeString("\'\'");
				startByte_ = endByte_ + 1;
				startChar_ = endChar_ + 1;
			}
			updateBreaks(c, Flag!"UpdateSpaces".yes);
		}
		while (endByte_ < text_.length);

		emitter_.writeIndicator("\'", No.needWhitespace);
	}

	///Write text as double quoted scalar.
	public void writeDoubleQuoted() {
		resetTextPosition();
		emitter_.writeIndicator("\"", Yes.needWhitespace);
		do {
			const dchar c = nextChar();
			//handle special characters
			if (c.among(dcharNone, '"', '\\', unicodeNewLines, '\uFEFF') || !((c >= '\x20' && c <= '\x7E') || ((c >= '\xA0' && c <= '\uD7FF') || (c >= '\uE000' && c <= '\uFFFD')))) {
				if (startChar_ < endChar_) {
					writeCurrentRange(Flag!"UpdateColumn".yes);
				}
				if (c != dcharNone) {
					auto appender = appender!string();
					if ((c in wyaml.escapes.toEscapes) !is null) {
						appender.put('\\');
						appender.put(wyaml.escapes.toEscapes[c]);
					} else {
						//Write an escaped Unicode character.
						const format = c <= 0xFF ? "\\x%02X" : c <= 0xFFFF ? "\\u%04X" : "\\U%08X";
						formattedWrite(appender, format, cast(uint) c);
					}

					emitter_.column_ += appender.data.length;
					emitter_.writeString(appender.data);
					startChar_ = endChar_ + 1;
					startByte_ = nextEndByte_;
				}
			}
			if ((endByte_ > 0 && endByte_ < text_.length - strideBack(text_, text_.length)) && (c == ' ' || startChar_ >= endChar_) && (emitter_.column_ + endChar_ - startChar_ > emitter_.bestWidth_) && split_) {
				//text_[2:1] is ok in Python but not in D, so we have to use min()
				emitter_.writeString(text_[min(startByte_, endByte_) .. endByte_]);
				emitter_.writeString("\\");
				emitter_.column_ += startChar_ - endChar_ + 1;
				startChar_ = max(startChar_, endChar_);
				startByte_ = max(startByte_, endByte_);

				writeIndent(Flag!"ResetSpace".yes);
				if (charAtStart() == ' ') {
					emitter_.writeString("\\");
					++emitter_.column_;
				}
			}
		}
		while (endByte_ < text_.length);
		emitter_.writeIndicator("\"", No.needWhitespace);
	}

	///Write text as folded block scalar.
	public void writeFolded() {
		initBlock('>');
		bool leadingSpace = true;
		spaces_ = false;
		breaks_ = true;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (breaks_) {
				if (!c.among(newLines)) {
					if (!leadingSpace && c != dcharNone && c != ' ') {
						writeStartLineBreak();
					}
					leadingSpace = (c == ' ');
					writeLineBreaks();
					if (c != dcharNone) {
						emitter_.writeIndent();
					}
				}
			} else if (spaces_) {
				if (c != ' ' && tooWide()) {
					writeIndent(Flag!"ResetSpace".no);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(Flag!"UpdateColumn".yes);
				}
			} else if (c.among(newLines, dcharNone, ' ')) {
				writeCurrentRange(Flag!"UpdateColumn".yes);
				if (c == dcharNone) {
					emitter_.writeLineBreak();
				}
			}
			updateBreaks(c, Flag!"UpdateSpaces".yes);
		}
		while (endByte_ < text_.length);
	}

	///Write text as literal block scalar.
	public void writeLiteral() {
		initBlock('|');
		breaks_ = true;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (breaks_) {
				if (!c.among(newLines)) {
					writeLineBreaks();
					if (c != dcharNone) {
						emitter_.writeIndent();
					}
				}
			} else if (c.among(dcharNone, newLines)) {
				writeCurrentRange(Flag!"UpdateColumn".no);
				if (c == dcharNone) {
					emitter_.writeLineBreak();
				}
			}
			updateBreaks(c, Flag!"UpdateSpaces".no);
		}
		while (endByte_ < text_.length);
	}

	///Write text as plain scalar.
	public void writePlain() {
		if (emitter_.context_ == Emitter!T.Context.Root) {
			emitter_.openEnded_ = true;
		}
		if (text_ == "") {
			return;
		}
		if (!emitter_.whitespace_) {
			++emitter_.column_;
			emitter_.writeString(" ");
		}
		emitter_.whitespace_ = emitter_.indentation_ = false;
		spaces_ = breaks_ = false;
		resetTextPosition();

		do {
			const dchar c = nextChar();
			if (spaces_) {
				if (c != ' ' && tooWide() && split_) {
					writeIndent(Flag!"ResetSpace".yes);
					updateRangeStart();
				} else if (c != ' ') {
					writeCurrentRange(Flag!"UpdateColumn".yes);
				}
			} else if (breaks_) {
				if (!c.among(newLines)) {
					writeStartLineBreak();
					writeLineBreaks();
					writeIndent(Flag!"ResetSpace".yes);
				}
			} else if (c.among(dcharNone, newLines, ' ')) {
				writeCurrentRange(Flag!"UpdateColumn".yes);
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
		size_t idx = startByte_;
		return decode(text_, idx);
	}

	///Is the current line too wide?
	private bool tooWide() const {
		return startChar_ + 1 == endChar_ && emitter_.column_ > emitter_.bestWidth_;
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
	private void initBlock(const char indicator) {
		char[4] hints;
		hints[0] = indicator;
		const hintsLength = 1 + determineBlockHints(hints[1 .. $], emitter_.bestIndent_);
		emitter_.writeIndicator(cast(string) hints[0 .. hintsLength], Yes.needWhitespace);
		if (hints.length > 0 && hints[$ - 1] == '+') {
			emitter_.openEnded_ = true;
		}
		emitter_.writeLineBreak();
	}

	///Write out the current text range.
	private void writeCurrentRange(const Flag!"UpdateColumn" updateColumn) {
		emitter_.writeString(text_[startByte_ .. endByte_]);
		if (updateColumn) {
			emitter_.column_ += endChar_ - startChar_;
		}
		updateRangeStart();
	}

	///Write line breaks in the text range.
	private void writeLineBreaks() {
		foreach (const dchar br; text_[startByte_ .. endByte_]) {
			if (br == '\n') {
				emitter_.writeLineBreak();
			} else {
				char[4] brString;
				const bytes = encode(brString, br);
				emitter_.writeLineBreak(cast(string) brString[0 .. bytes]);
			}
		}
		updateRangeStart();
	}

	///Write line break if start of the text range is a newline.
	private void writeStartLineBreak() {
		if (charAtStart == '\n') {
			emitter_.writeLineBreak();
		}
	}

	///Write indentation, optionally resetting whitespace/indentation flags.
	private void writeIndent(const Flag!"ResetSpace" resetSpace) {
		emitter_.writeIndent();
		if (resetSpace) {
			emitter_.whitespace_ = emitter_.indentation_ = false;
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

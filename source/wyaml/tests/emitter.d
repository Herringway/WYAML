//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.emitter;

unittest {
	import std.algorithm : among;
	import std.conv : text;
	import std.outbuffer : OutBuffer;
	import std.range : lockstep;
	import std.typecons : tuple, AliasSeq;

	import wyaml.dumper;
	import wyaml.event;
	import wyaml.tests.common;
	import wyaml.token;

	/// Determine if events in events1 are equivalent to events in events2.
	///
	/// Params:  events1 = First event array to compare.
	///          events2 = Second event array to compare.
	///
	/// Returns: true if the events are equivalent, false otherwise.
	bool compareEvents(Event[] events1, Event[] events2) {
		if (events1.length != events2.length) {
			return false;
		}

		foreach (e1, e2; lockstep(events1, events2)) {

			//Different event types.
			if (e1.id != e2.id) {
				return false;
			}
			//Different anchor (if applicable).
			if (e1.id.among!(EventID.SequenceStart, EventID.MappingStart, EventID.Alias, EventID.Scalar) && !e1.anchor.isNull && !e2.anchor.isNull && e1.anchor != e2.anchor) {
				return false;
			}
			//Different collection tag (if applicable).
			if (e1.id.among!(EventID.SequenceStart, EventID.MappingStart) && !e1.tag.isNull && !e2.tag.isNull && e1.tag != e2.tag) {
				return false;
			}

			if (e1.id == EventID.Scalar) {
				//Different scalar tag (if applicable).
				if (!e1.implicit && !e1.implicit_2 && !e2.implicit && !e2.implicit_2 && e1.tag != e2.tag) {
					return false;
				}
				//Different scalar value.
				if (e1.value != e2.value) {
					return false;
				}
			}
		}
		return true;
	}

	/// Test emitter by parsing data to get events, emitting them, parsing
	/// the emitted result and comparing events from parsing the emitted result with
	/// originally parsed events.
	///
	/// Params:  data      = YAML data to parse.
	void testEmitterOnData(string data, string testName) {
		//Must exist due to Anchor, Tags reference counts.
		auto loader = Loader(data);
		auto events = cast(Event[]) loader.parse();
		auto emitStream = new OutBuffer;
		Dumper().emit(emitStream, events);
		scope (failure) {
			writeComparison!("Original", "Output")(testName, data, emitStream.text);
		}
		auto loader2 = Loader(emitStream.text);
		loader2.name = "TEST";
		loader2.constructor = new Constructor;
		loader2.resolver = new Resolver;
		auto newEvents = cast(Event[]) loader2.parse();
		assert(compareEvents(events, newEvents));
	}

	/// Test emitter by getting events from parsing canonical YAML data, emitting
	/// them both in canonical and normal format, parsing the emitted results and
	/// comparing events from parsing the emitted result with originally parsed events.
	///
	/// Params:  canonical = Canonical YAML data to parse.
	void testEmitterOnCanonical(string canonicalData, string testName) {
		//Must exist due to Anchor, Tags reference counts.
		auto loader = Loader(canonicalData);
		auto events = cast(Event[]) loader.parse();
		foreach (canonical; [false, true]) {
			auto emitStream = new OutBuffer;
			auto dumper = Dumper();
			dumper.canonical = canonical;
			dumper.emit(emitStream, events);
			scope (failure) {
				writeComparison!("Canonical", "Output")(testName, canonical, emitStream.text);
			}
			auto loader2 = Loader(emitStream.text);
			loader2.name = "TEST";
			loader2.constructor = new Constructor;
			loader2.resolver = new Resolver;
			auto newEvents = cast(Event[]) loader2.parse();
			assert(compareEvents(events, newEvents));
		}
	}

	/// Test emitter by getting events from parsing a file, emitting them with all
	/// possible scalar and collection styles, parsing the emitted results and
	/// comparing events from parsing the emitted result with originally parsed events.
	///
	/// Params:  dataFilename      = YAML file to parse.
	///          canonicalFilename = Canonical YAML file used as dummy to determine
	///                              which data files to load.
	void testEmitterStyles(string canonical, string testName) {
		//must exist due to Anchor, Tags reference counts
		auto loader = Loader(canonical);
		auto events = cast(Event[]) loader.parse();
		foreach (flowStyle; [CollectionStyle.Block, CollectionStyle.Flow]) {
			foreach (style; [ScalarStyle.Literal, ScalarStyle.Folded, ScalarStyle.DoubleQuoted, ScalarStyle.SingleQuoted, ScalarStyle.Plain]) {
				Event[] styledEvents;
				foreach (event; events) {
					if (event.id == EventID.Scalar) {
						event = scalarEvent(Mark(), Mark(), event.anchor, event.tag, tuple(event.implicit, event.implicit_2), event.value, style);
					} else if (event.id == EventID.SequenceStart) {
						event = sequenceStartEvent(Mark(), Mark(), event.anchor, event.tag, event.implicit, flowStyle);
					} else if (event.id == EventID.MappingStart) {
						event = mappingStartEvent(Mark(), Mark(), event.anchor, event.tag, event.implicit, flowStyle);
					}
					styledEvents ~= event;
				}
				auto emitStream = new OutBuffer;
				Dumper().emit(emitStream, styledEvents);
				scope (failure) {
					writeComparison!("Original", "Output")(testName, flowStyle.text ~ style.text, emitStream.text);
				}
				auto loader2 = Loader(emitStream.text);
				loader2.name = "TEST";
				loader2.constructor = new Constructor;
				loader2.resolver = new Resolver;
				auto newEvents = cast(Event[]) loader2.parse();
				assert(compareEvents(events, newEvents));
			}
		}
	}

	alias testSet = AliasSeq!("emit-block-scalar-in-simple-key-context-bug", "empty-document-bug", "scan-document-end-bug", "scan-line-break-bug", "sloppy-indentation", "spec-05-03", "spec-05-04", "spec-05-06", "spec-05-07", "spec-05-08", "spec-05-09", "spec-05-11", "spec-05-13", "spec-05-14", "spec-06-01", "spec-06-03", "spec-06-04", "spec-06-05", "spec-06-06", "spec-06-07", "spec-06-08", "spec-07-01", "spec-07-02", "spec-07-04", "spec-07-06", "spec-07-07a", "spec-07-07b", "spec-07-08", "spec-07-09", "spec-07-10", "spec-07-12a", "spec-07-12b", "spec-07-13", "spec-08-01", "spec-08-02", "spec-08-03", "spec-08-05", "spec-08-07", "spec-08-08", "spec-08-09", "spec-08-10", "spec-08-11", "spec-08-12", "spec-08-13", "spec-08-14", "spec-08-15", "spec-09-01", "spec-09-02", "spec-09-03", "spec-09-04", "spec-09-05", "spec-09-06", "spec-09-07", "spec-09-08", "spec-09-09", "spec-09-10", "spec-09-11", "spec-09-12", "spec-09-13", "spec-09-15", "spec-09-16", "spec-09-17", "spec-09-18", "spec-09-19", "spec-09-20", "spec-09-22", "spec-09-23", "spec-09-24", "spec-09-25", "spec-09-26", "spec-09-27", "spec-09-28", "spec-09-29", "spec-09-30", "spec-09-31", "spec-09-32", "spec-09-33", "spec-10-01", "spec-10-02", "spec-10-03", "spec-10-04", "spec-10-05", "spec-10-06", "spec-10-07", "spec-10-09", "spec-10-10", "spec-10-11", "spec-10-12", "spec-10-13", "spec-10-14", "spec-10-15");
	run2!(testEmitterOnData, ["data"], testSet)("Emitter on Data");
	run2!(testEmitterOnCanonical, ["canonical"], testSet)("Emitter on Canonical");
	run2!(testEmitterStyles, ["canonical"], testSet)("Emitter Styles");
}

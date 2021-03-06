//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * YAML serializer.
 * Code based on PyYAML: http://www.pyyaml.org
 */
module wyaml.serializer;

import std.array;
import std.conv;
import std.format;
import std.typecons;

import wyaml.anchor;
import wyaml.emitter;
import wyaml.event;
import wyaml.exception;
import wyaml.node;
import wyaml.resolver;
import wyaml.tag;
import wyaml.tagdirective;
import wyaml.token;

///Serializes represented YAML nodes, generating events which are then emitted by Emitter.
package struct Serializer(T) {
	///Emitter to emit events produced.
	private Emitter!T* emitter_;
	///Resolver used to determine which tags are automaticaly resolvable.
	private Resolver resolver_;

	///Do all document starts have to be specified explicitly?
	private Flag!"explicitStart" explicitStart_;
	///Do all document ends have to be specified explicitly?
	private Flag!"explicitEnd" explicitEnd_;
	///YAML version string.
	private string yamlVersion_;

	///Tag directives to emit.
	private TagDirective[] tagDirectives_;

	//TODO Use something with more deterministic memory usage.
	///Nodes with assigned anchors.
	private Anchor[Node] anchors_;
	///Nodes with assigned anchors that are already serialized.
	private bool[Node] serializedNodes_;
	///ID of the last anchor generated.
	private uint lastAnchorID_ = 0;

	/**
		 * Construct a Serializer.
		 *
		 * Params:  emitter       = Emitter to emit events produced.
		 *          resolver      = Resolver used to determine which tags are automaticaly resolvable.
		 *          explicitStart = Do all document starts have to be specified explicitly?
		 *          explicitEnd   = Do all document ends have to be specified explicitly?
		 *          YAMLVersion   = YAML version string.
		 *          tagDirectives = Tag directives to emit.
		 */
	public this(ref Emitter!T emitter, Resolver resolver, const Flag!"explicitStart" explicitStart, const Flag!"explicitEnd" explicitEnd, string YAMLVersion, TagDirective[] tagDirectives) {
		emitter_ = &emitter;
		resolver_ = resolver;
		explicitStart_ = explicitStart;
		explicitEnd_ = explicitEnd;
		yamlVersion_ = YAMLVersion;
		tagDirectives_ = tagDirectives;

		emitter_.emit(Event(EventID.StreamStart));
	}

	///Destroy the Serializer.
	public ~this() {
		emitter_.emit(Event(EventID.StreamEnd));
	}

	///Serialize a node, emitting it in the process.
	public void serialize(ref Node node) {
		emitter_.emit(documentStartEvent(explicitStart_, yamlVersion_, tagDirectives_));
		anchorNode(node);
		serializeNode(node);
		emitter_.emit(documentEndEvent(explicitEnd_));
		serializedNodes_.clear();
		anchors_.clear();
		lastAnchorID_ = 0;
	}

	/**
		 * Determine if it's a good idea to add an anchor to a node.
		 *
		 * Used to prevent associating every single repeating scalar with an
		 * anchor/alias - only nodes long enough can use anchors.
		 *
		 * Params:  node = Node to check for anchorability.
		 *
		 * Returns: True if the node is anchorable, false otherwise.
		 */
	private static bool anchorable(ref Node node) {
		if (node.isScalar) {
			return node.isType!string ? node.to!string.length > 64 : node.isType!(ubyte[]) ? node.to!(ubyte[]).length > 64 : false;
		}
		return node.length > 2;
	}

	///Add an anchor to the node if it's anchorable and not anchored yet.
	private void anchorNode(ref Node node) {
		if (!anchorable(node)) {
			return;
		}

		if ((node in anchors_) !is null) {
			if (anchors_[node].isNull()) {
				anchors_[node] = generateAnchor();
			}
			return;
		}

		anchors_[node] = Anchor(null);
		if (node.isSequence) {
			foreach (ref Node item; node) {
				anchorNode(item);
			}
		} else if (node.isMapping) {
			foreach (ref Node key, ref Node value; node) {
				anchorNode(key);
				anchorNode(value);
			}
		}
	}

	///Generate and return a new anchor.
	private Anchor generateAnchor() {
		++lastAnchorID_;
		auto appender = appender!string();
		formattedWrite(appender, "id%03d", lastAnchorID_);
		return Anchor(appender.data);
	}

	///Serialize a node and all its subnodes.
	private void serializeNode(ref Node node) {
		//If the node has an anchor, emit an anchor (as aliasEvent) on the
		//first occurrence, save it in serializedNodes_, and emit an alias
		//if it reappears.
		Anchor aliased = Anchor();
		if (anchorable(node) && (node in anchors_) !is null) {
			aliased = anchors_[node];
			if ((node in serializedNodes_) !is null) {
				emitter_.emit(Event(EventID.Alias, aliased));
				return;
			}
			serializedNodes_[node] = true;
		}

		if (node.isScalar) {
			assert(node.isType!string, "Scalar node type must be string before serialized");
			auto value = node.to!string;
			const detectedTag = resolver_.resolve(NodeID.Scalar, Tag(null), value, true);
			const defaultTag = resolver_.resolve(NodeID.Scalar, Tag(null), value, false);
			bool isDetected = node.tag_ == detectedTag;
			bool isDefault = node.tag_ == defaultTag;

			emitter_.emit(scalarEvent(Mark(), Mark(), aliased, node.tag_, tuple(isDetected, isDefault), value, node.scalarStyle));
			return;
		}
		if (node.isSequence) {
			const defaultTag = resolver_.defaultSequenceTag;
			const implicit = node.tag_ == defaultTag;
			emitter_.emit(collectionStartEvent(EventID.SequenceStart, Mark(), Mark(), aliased, node.tag_, implicit, node.collectionStyle));
			foreach (ref Node item; node) {
				serializeNode(item);
			}
			emitter_.emit(Event(EventID.SequenceEnd));
			return;
		}
		if (node.isMapping) {
			const defaultTag = resolver_.defaultMappingTag;
			const implicit = node.tag_ == defaultTag;
			emitter_.emit(collectionStartEvent(EventID.MappingStart, Mark(), Mark(), aliased, node.tag_, implicit, node.collectionStyle));
			foreach (ref Node key, ref Node value; node) {
				serializeNode(key);
				serializeNode(value);
			}
			emitter_.emit(Event(EventID.MappingEnd));
			return;
		}
		assert(false, "This code should never be reached");
	}
}

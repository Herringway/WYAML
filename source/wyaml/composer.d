//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * Composes nodes from YAML events provided by parser.
 * Code based on PyYAML: http://www.pyyaml.org
 */
module wyaml.composer;

import std.array;
import std.conv;
import std.exception;
import std.typecons;

import wyaml.anchor;
import wyaml.constructor;
import wyaml.event;
import wyaml.exception;
import wyaml.node;
import wyaml.parser;
import wyaml.resolver;

/**
 * Exception thrown at composer errors.
 *
 * See_Also: MarkedYAMLException
 */
package class ComposerException : MarkedYAMLException {
	mixin MarkedExceptionCtors;
}

///Composes YAML documents from events provided by a Parser.
package final class Composer {
	///Parser providing YAML events.
	private Parser parser_;
	///Resolver resolving tags (data types).
	private Resolver resolver_;
	///Constructor constructing YAML values.
	private Constructor constructor_;
	///Nodes associated with anchors. Used by YAML aliases.
	private Node[Anchor] anchors_;

	///Used to reduce allocations when creating pair arrays.
	///
	///We need one appender for each nesting level that involves
	///a pair array, as the inner levels are processed as a
	///part of the outer levels. Used as a stack.
	private Appender!(Node.Pair[])[] pairAppenders_;
	///Used to reduce allocations when creating node arrays.
	///
	///We need one appender for each nesting level that involves
	///a node array, as the inner levels are processed as a
	///part of the outer levels. Used as a stack.
	private Appender!(Node[])[] nodeAppenders_;

	/**
		 * Construct a composer.
		 *
		 * Params:  parser      = Parser to provide YAML events.
		 *          resolver    = Resolver to resolve tags (data types).
		 *          constructor = Constructor to construct nodes.
		 */
	public this(Parser parser, Resolver resolver, Constructor constructor) @safe {
		parser_ = parser;
		resolver_ = resolver;
		constructor_ = constructor;
	}

	/**
		 * Determine if there are any nodes left.
		 *
		 * Must be called before loading as it handles the stream start event.
		 */
	public bool checkNode() @safe {
		//Drop the STREAM-START event.
		if (parser_.checkEvent(EventID.StreamStart)) {
			parser_.getEvent();
		}

		//True if there are more documents available.
		return !parser_.checkEvent(EventID.StreamEnd);
	}

	///Get a YAML document as a node (the root of the document).
	public Node getNode() {
		//Get the root node of the next document.
		assert(!parser_.checkEvent(EventID.StreamEnd), "Trying to get a node from Composer when there is no node to get. use checkNode() to determine if there is a node.");

		return composeDocument();
	}

	///Ensure that appenders for specified nesting levels exist.
	///
	///Params:  pairAppenderLevel = Current level in the pair appender stack.
	///         nodeAppenderLevel = Current level the node appender stack.
	private void ensureAppendersExist(const uint pairAppenderLevel, const uint nodeAppenderLevel) @safe {
		while (pairAppenders_.length <= pairAppenderLevel) {
			pairAppenders_ ~= appender!(Node.Pair[])();
		}
		while (nodeAppenders_.length <= nodeAppenderLevel) {
			nodeAppenders_ ~= appender!(Node[])();
		}
	}

	///Compose a YAML document and return its root node.
	private Node composeDocument() {
		//Drop the DOCUMENT-START event.
		parser_.getEvent();

		//Compose the root node.
		Node node = composeNode(0, 0);

		//Drop the DOCUMENT-END event.
		parser_.getEvent();

		anchors_.clear();
		return node;
	}

	/// Compose a node.
	///
	/// Params: pairAppenderLevel = Current level of the pair appender stack.
	///         nodeAppenderLevel = Current level of the node appender stack.
	private Node composeNode(const uint pairAppenderLevel, const uint nodeAppenderLevel) {
		if (parser_.checkEvent(EventID.Alias)) {
			immutable event = parser_.getEvent();
			const anchor = event.anchor;
			enforce((anchor in anchors_) !is null, new ComposerException("Found undefined alias: " ~ anchor.get, event.startMark));

			//If the node referenced by the anchor is uninitialized,
			//it's not finished, i.e. we're currently composing it
			//and trying to use it recursively here.
			enforce(anchors_[anchor] != Node(), new ComposerException("Found recursive alias: " ~ anchor.get, event.startMark));

			return anchors_[anchor];
		}

		immutable event = parser_.peekEvent();
		const anchor = event.anchor;
		if (!anchor.isNull() && (anchor in anchors_) !is null) {
			throw new ComposerException("Found duplicate anchor: " ~ anchor.get, event.startMark);
		}

		Node result;
		//Associate the anchor, if any, with an uninitialized node.
		//used to detect duplicate and recursive anchors.
		if (!anchor.isNull()) {
			anchors_[anchor] = Node();
		}

		if (parser_.checkEvent(EventID.Scalar)) {
			result = composeScalarNode();
		} else if (parser_.checkEvent(EventID.SequenceStart)) {
			result = composeSequenceNode(pairAppenderLevel, nodeAppenderLevel);
		} else if (parser_.checkEvent(EventID.MappingStart)) {
			result = composeMappingNode(pairAppenderLevel, nodeAppenderLevel);
		} else {
			assert(false, "This code should never be reached");
		}

		if (!anchor.isNull()) {
			anchors_[anchor] = result;
		}
		return result;
	}

	///Compose a scalar node.
	private Node composeScalarNode() {
		immutable event = parser_.getEvent();
		const tag = resolver_.resolve(NodeID.Scalar, event.tag, event.value, event.implicit);

		Node node = constructor_.node(event.startMark, event.endMark, tag, event.value, event.scalarStyle);

		return node;
	}

	/// Compose a sequence node.
	///
	/// Params: pairAppenderLevel = Current level of the pair appender stack.
	///         nodeAppenderLevel = Current level of the node appender stack.
	private Node composeSequenceNode(const uint pairAppenderLevel, const uint nodeAppenderLevel) {
		ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
		auto nodeAppender = &(nodeAppenders_[nodeAppenderLevel]);

		immutable startEvent = parser_.getEvent();
		const tag = resolver_.resolve(NodeID.Sequence, startEvent.tag, null, startEvent.implicit);

		while (!parser_.checkEvent(EventID.SequenceEnd)) {
			nodeAppender.put(composeNode(pairAppenderLevel, nodeAppenderLevel + 1));
		}

		Node node = constructor_.node(startEvent.startMark, parser_.getEvent().endMark, tag, nodeAppender.data.dup, startEvent.collectionStyle);
		nodeAppender.clear();

		return node;
	}

	/**
		 * Flatten a node, merging it with nodes referenced through YAMLMerge data type.
		 *
		 * Node must be a mapping or a sequence of mappings.
		 *
		 * Params:  root              = Node to flatten.
		 *          startMark         = Start position of the node.
		 *          endMark           = End position of the node.
		 *          pairAppenderLevel = Current level of the pair appender stack.
		 *          nodeAppenderLevel = Current level of the node appender stack.
		 *
		 * Returns: Flattened mapping as pairs.
		 */
	private Node.Pair[] flatten(ref Node root, const Mark startMark, const Mark endMark, const uint pairAppenderLevel, const uint nodeAppenderLevel) {
		void error(Node node) {
			//this is Composer, but the code is related to Constructor.
			throw new ComposerException(
				"While constructing a mapping, expected a mapping or a list of mappings for merging, but found: " ~ node.type.text ~ " NOTE: line/column shows topmost parent to which the content is being merged",
				startMark, endMark);
		}

		ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
		auto pairAppender = &(pairAppenders_[pairAppenderLevel]);

		if (root.isMapping) {
			Node[] toMerge;
			foreach (ref Node key, ref Node value; root) {
				if (key.isType!YAMLMerge) {
					toMerge.assumeSafeAppend();
					toMerge ~= value;
				} else {
					auto temp = Node.Pair(key, value);
					merge(*pairAppender, temp);
				}
			}
			foreach (node; toMerge) {
				merge(*pairAppender, flatten(node, startMark, endMark, pairAppenderLevel + 1, nodeAppenderLevel));
			}
		}  //Must be a sequence of mappings.
		else if (root.isSequence)
			foreach (ref Node node; root) {
				if (!node.isType!(Node.Pair[])) {
					error(node);
				}
				merge(*pairAppender, flatten(node, startMark, endMark, pairAppenderLevel + 1, nodeAppenderLevel));
			} else {
			error(root);
		}

		auto flattened = pairAppender.data;
		pairAppender.clear();

		return flattened;
	}

	/// Compose a mapping node.
	///
	/// Params: pairAppenderLevel = Current level of the pair appender stack.
	///         nodeAppenderLevel = Current level of the node appender stack.
	private Node composeMappingNode(const uint pairAppenderLevel, const uint nodeAppenderLevel) {
		ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
		immutable startEvent = parser_.getEvent();
		const tag = resolver_.resolve(NodeID.Mapping, startEvent.tag, null, startEvent.implicit);
		auto pairAppender = &(pairAppenders_[pairAppenderLevel]);

		Tuple!(Node, Mark)[] toMerge;
		while (!parser_.checkEvent(EventID.MappingEnd)) {
			auto pair = Node.Pair(composeNode(pairAppenderLevel + 1, nodeAppenderLevel), composeNode(pairAppenderLevel + 1, nodeAppenderLevel));

			//Need to flatten and merge the node referred by YAMLMerge.
			if (pair.key.isType!YAMLMerge) {
				toMerge ~= tuple(pair.value, cast(Mark) parser_.peekEvent().endMark);
			} else { //Not YAMLMerge, just add the pair.
				merge(*pairAppender, pair);
			}
		}
		foreach (node; toMerge) {
			merge(*pairAppender, flatten(node[0], startEvent.startMark, node[1], pairAppenderLevel + 1, nodeAppenderLevel));
		}

		Node node = constructor_.node(startEvent.startMark, parser_.getEvent().endMark, tag, pairAppender.data.dup, startEvent.collectionStyle);

		pairAppender.clear();
		return node;
	}
}

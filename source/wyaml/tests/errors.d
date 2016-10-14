//          Copyright Ferdinand Majerech 2011-2014
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.errors;

unittest {
	import std.array : array;
	import std.exception : assertThrown;
	import std.meta : AliasSeq;

	import wyaml.tests.common;

	/// Loader error unittest from file stream.
	///
	/// Params:  buffer = Data to expect errors from.
	void testLoaderError(string buffer, string) {
		assertThrown(Loader(buffer).loadAll().array);
	}

	alias errorTests = AliasSeq!("a-nasty-libyaml-bug", "colon-in-flow-context", "document-separator-in-quoted-scalar", "duplicate-anchor-1", "duplicate-anchor-2", "duplicate-tag-directive",
		"duplicate-yaml-directive", "empty-python-module", "empty-python-name", "expected-mapping", "expected-scalar", "expected-sequence", "fetch-complex-value-bug", "forbidden-entry",
		"forbidden-key", "forbidden-value", "invalid-anchor-1", "invalid-anchor-2", "invalid-base64-data-2", "invalid-base64-data", "invalid-block-scalar-indicator", "invalid-character",
		"invalid-directive-line", "invalid-directive-name-1", "invalid-directive-name-2", "invalid-escape-character", "invalid-escape-numbers", "invalid-indentation-indicator-1",
		"invalid-indentation-indicator-2", "invalid-item-without-trailing-break", "invalid-merge-1", "invalid-merge-2", "invalid-omap-1", "invalid-omap-2", "invalid-omap-3", "invalid-pairs-1",
		"invalid-pairs-2", "invalid-pairs-3", "invalid-simple-key", "invalid-starting-character", "invalid-tag-1", "invalid-tag-2", "invalid-tag-directive-handle", "invalid-tag-directive-prefix",
		"invalid-tag-handle-1", "invalid-tag-handle-2", "invalid-uri-escapes-1", "invalid-uri-escapes-2", "invalid-uri-escapes-3", "invalid-uri", "invalid-yaml-directive-version-1",
		"invalid-yaml-directive-version-2", "invalid-yaml-directive-version-3", "invalid-yaml-directive-version-4", "invalid-yaml-directive-version-5", "invalid-yaml-directive-version-6",
		"invalid-yaml-version", "no-block-collection-end", "no-block-mapping-end-2", "no-block-mapping-end", "no-document-start", "no-flow-mapping-end", "no-flow-sequence-end", "no-node-1",
		"no-node-2", "remove-possible-simple-key-bug", "unclosed-bracket", "unclosed-quoted-scalar", "undefined-anchor", "undefined-constructor", "undefined-tag-handle");
	run2!(testLoaderError, ["loader-error"], errorTests)("Errors");
}

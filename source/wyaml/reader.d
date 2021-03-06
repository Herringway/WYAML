//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.reader;

import std.algorithm;
import std.conv;
import std.range;
import std.utf;

import wyaml.exception;

///Exception thrown at Reader errors.
package class ReaderException : YAMLException {
	this(string msg, string file = __FILE__, int line = __LINE__) @safe pure nothrow {
		super("Reader error: " ~ msg, file, line);
	}
}

package final class Reader {
	// Buffer of currently loaded characters.
	private string buffer_ = void;

	// Current position within buffer. Only data after this position can be read.
	private size_t bufferOffset_ = 0;

	// Current line in file.
	private uint line_;
	// Current column in file.
	private uint column_;

	/// Construct a Reader.
	///
	/// Params:  buffer = Buffer with YAML data.
	public this(in char[] buffer) pure @safe nothrow {
		buffer_ = buffer.idup;
	}

	public this(string buffer) pure @safe nothrow @nogc {
		buffer_ = buffer;
	}

	private this() @safe {
	}

	public immutable(dchar) front() @safe
	out (result) {
		assert(isPrintableChar(result));
	} body {
		auto lastDecodedBufferOffset_ = bufferOffset_;
		return decode(buffer_, lastDecodedBufferOffset_);
	}

	///Returns a copy
	public Reader save() @safe {
		auto output = new Reader();
		output.buffer_ = buffer_;
		output.bufferOffset_ = bufferOffset_;
		output.line_ = line_;
		output.column_ = column_;
		return output;
	}

	public bool empty() @safe const {
		return bufferOffset_ >= buffer_.length;
	}

	/// Move current position forward by one character.
	public void popFront() @safe
	in {
		assert(!empty);
	} body {

		const c = decode(buffer_, bufferOffset_);

		// New line. (can compare with '\n' without decoding since it's ASCII)
		if (c.among!('\n', '\u0085', '\u2028', '\u2029') || (c == '\r' && buffer_[bufferOffset_] != '\n')) {
			++line_;
			column_ = 0;
		} else
			++column_;

	}

	/// Get a string describing current buffer position, used for error messages.
	public Mark mark() @nogc nothrow const @safe pure {
		return Mark(line_, column_);
	}

	/// Get current line number.
	public uint line() const @safe pure {
		return line_;
	}

	/// Get current column number.
	public uint column() const @safe pure {
		return column_;
	}
}

private bool isPrintableChar(in dchar val) pure @safe nothrow @nogc {
	if (val < 0x20 && !val.among(0x09, 0x0A, 0x0D))
		return false;
	if (val < 0xA0 && val >= 0x80 && val != 0x85)
		return false;
	if (val.among(0x7F, 0xFEFF, 0xFFFE, 0xFFFF))
		return false;
	return true;
}
// Unittests.

unittest {
	void testPeekPrefixForward(R)() {
		char[] data = "data".dup;
		auto reader = new R(data);
		assert(reader.save().startsWith("data"));
		reader.popFrontN(2);
	}

	void testUTF(R)() {
		dchar[] data = cast(dchar[]) "data";
		void utf_test(T)(T[] data) {
			char[] bytes = data.to!(char[]);
			auto reader = new R(bytes);
			assert(reader.startsWith("data"));
		}

		utf_test!char(to!(char[])(data));
		utf_test!wchar(to!(wchar[])(data));
		utf_test(data);
	}

	void test1Byte(R)() {
		char[] data = [97];

		auto reader = new R(data);
		assert(reader.front == 'a');
		reader.popFront();
		assert(reader.empty);
	}

	testPeekPrefixForward!Reader();
	testUTF!Reader();
	test1Byte!Reader();
}

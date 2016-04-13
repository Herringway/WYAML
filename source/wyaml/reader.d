
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.reader;


import core.stdc.stdlib;
import core.stdc.string;
import core.thread;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.range;
import std.stdio;
import std.string;
import std.system;
import std.typecons;
import std.utf;

import wyaml.exception;



package:


///Exception thrown at Reader errors.
class ReaderException : YAMLException
{
    this(string msg, string file = __FILE__, int line = __LINE__)
        @safe pure nothrow
    {
        super("Reader error: " ~ msg, file, line);
    }
}

final class Reader
{
    private:
        // Buffer of currently loaded characters.
        string buffer_ = void;

        // Current position within buffer. Only data after this position can be read.
        size_t bufferOffset_ = 0;

        // Current line in file.
        uint line_;
        // Current column in file.
        uint column_;

    public:
        /// Construct a Reader.
        ///
        /// Params:  buffer = Buffer with YAML data.
        this(in char[] buffer) pure @safe nothrow {
            buffer_ = buffer.idup;
        }
        this(string buffer) pure @safe nothrow @nogc {
            buffer_ = buffer;
        }
        private this() @safe { }
        immutable(dchar) front() @safe out(result) {
            assert(isPrintableChar(result));
        } body {
            auto lastDecodedBufferOffset_ = bufferOffset_;
            return decode(buffer_, lastDecodedBufferOffset_);
        }

        ///Returns a copy
        Reader save() @safe {
            auto output = new Reader();
            output.buffer_ = buffer_;
            output.bufferOffset_ = bufferOffset_;
            output.line_ = line_;
            output.column_ = column_;
            return output;
        }

        bool empty() @safe const {
            return bufferOffset_ >= buffer_.length;
        }

        /// Move current position forward by one character.
        void popFront() @safe in {
            assert(!empty);
        } body {

            const c = decode(buffer_, bufferOffset_);

            // New line. (can compare with '\n' without decoding since it's ASCII)
            if(c.among!('\n', '\u0085', '\u2028', '\u2029') || (c == '\r' && buffer_[bufferOffset_] != '\n'))
            {
                ++line_;
                column_ = 0;
            }
            else if(c != '\uFEFF') { ++column_; }

        }

@safe pure:
        /// Get a string describing current buffer position, used for error messages.
        Mark mark() @nogc nothrow const { return Mark(line_, column_); }

        /// Get current line number.
        uint line() const { return line_; }

        /// Get current column number.
        uint column() const { return column_; }
}
private:
bool isPrintableChar(in dchar val) pure @safe nothrow @nogc {
    if (val < 0x20 && !val.among(0x09, 0x0A, 0x0D))
        return false;
    if (val < 0xA0 && val >= 0x80 && val != 0x85)
        return false;
    if (val.among(0x7F, 0xFEFF, 0xFFFE, 0xFFFF))
        return false;
    return true;
}
// Unittests.

void testPeekPrefixForward(R)()
{
    char[] data = "data".dup;
    auto reader = new R(data);
    assert(reader.save().startsWith("data"));
    reader.popFrontN(2);
}

void testUTF(R)()
{
    dchar[] data = cast(dchar[])"data";
    void utf_test(T)(T[] data)
    {
        char[] bytes = data.to!(char[]);
        auto reader = new R(bytes);
        assert(reader.startsWith("data"));
    }
    utf_test!char(to!(char[])(data));
    utf_test!wchar(to!(wchar[])(data));
    utf_test(data);
}

void test1Byte(R)()
{
    char[] data = [97];

    auto reader = new R(data);
    assert(reader.front == 'a');
    reader.popFront();
    assert(reader.empty);
}

unittest
{
    testPeekPrefixForward!Reader();
    testUTF!Reader();
    test1Byte!Reader();
}

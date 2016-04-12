
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

import tinyendian;

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

/// Provides an API to read characters from a UTF-8 buffer and build slices into that
/// buffer to avoid allocations (see SliceBuilder).
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
        /// Params:  buffer = Buffer with YAML data. This may be e.g. the entire
        ///                   contents of a file or a string. $(B will) be modified by
        ///                   the Reader and other parts of D:YAML (D:YAML tries to
        ///                   reuse the buffer to minimize memory allocations)
        ///
        /// Throws:  ReaderException on a UTF decoding error or if there are
        ///          nonprintable Unicode characters illegal in YAML.
        this(in char[] buffer) pure
        {
            auto endianResult = fixUTFByteOrder(cast(ubyte[])buffer);
            if(endianResult.bytesStripped > 0)
            {
                throw new ReaderException("Size of UTF-16 or UTF-32 input not aligned "
                                          "to 2 or 4 bytes, respectively");
            }

            auto utf8Result = toUTF8(endianResult.array, endianResult.encoding);

            buffer_ = utf8Result.idup;
            //buffer_ = buffer;

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

// Convert a UTF-8/16/32 buffer to UTF-8, in-place if possible.
//
// Params:
//
// input    = Buffer with UTF-8/16/32 data to decode. May be overwritten by the
//            conversion, in which case the result will be a slice of this buffer.
// encoding = Encoding of input.
//
// Returns:
//
// A struct with the following members:
//
// $(D string errorMessage)   In case of an error, the error message is stored here. If
//                            there was no error, errorMessage is NULL. Always check
//                            this first.
// $(D char[] utf8)           input converted to UTF-8. May be a slice of input.
// $(D size_t characterCount) Number of characters (code points) in input.
deprecated char[] toUTF8(ubyte[] input, const UTFEncoding encoding) @safe pure
{

    char[] result;

    // Encode input_ into UTF-8 if it's encoded as UTF-16 or UTF-32.
    //
    // Params:
    //
    // buffer = The input buffer to encode.
    // result = A Result struct to put encoded result and any error messages to.
    //
    // On error, result.errorMessage will be set.
    static void encode(C)(C[] input, ref char[] result) @safe pure
    {
        // We can do UTF-32->UTF-8 in place because all UTF-8 sequences are 4 or
        // less bytes.
        static if(is(C == dchar))
        {
            char[4] encodeBuf;
            auto utf8 = cast(char[])input;
            auto length = 0;
            foreach(dchar c; input) {
                const encodeResult = std.utf.encode(encodeBuf, c);
                utf8[length .. length + encodeResult] = encodeBuf[0 .. encodeResult];
                length += encodeResult;
            }
            result = utf8[0 .. length];
        }
        // Unfortunately we can't do UTF-16 in place so we just use std.conv.to
        else
        {
            result = input.to!(char[]);
        }
    }

    final switch(encoding)
    {
        case UTFEncoding.UTF_8:
            encode(cast(char[])input, result);
            break;
        case UTFEncoding.UTF_16:
            assert(input.length % 2 == 0, "UTF-16 buffer size must be even");
            encode(cast(wchar[])input, result);
            break;
        case UTFEncoding.UTF_32:
            assert(input.length % 4 == 0, "UTF-32 buffer size must be a multiple of 4");
            encode(cast(dchar[])input, result);
            break;
    }

    return result;
}
bool isPrintableChar(in dchar val) pure @safe nothrow @nogc {
    if (val < 0x20 && !val.among(0x09, 0x0A, 0x0D))
        return false;
    if (val < 0xA0 && val >= 0x80 && val != 0x85)
        return false;
    if (val.among(0x7F, 0xFFFE, 0xFFFF))
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

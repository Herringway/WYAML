
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.reader;


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

import dyaml.exception;



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
        char[] buffer_ = null;

        // Current position within buffer. Only data after this position can be read.
        size_t bufferOffset_ = 0;

        // Index of the current character in the buffer.
        size_t charIndex_ = 0;
        // Number of characters (code points) in buffer_.
        size_t characterCount_ = 0;

        // Current line in file.
        uint line_;
        // Current column in file.
        uint column_;

        // The number of consecutive ASCII characters starting at bufferOffset_.
        //
        // Used to minimize UTF-8 decoding.
        size_t upcomingASCII_ = 0;

        // Index to buffer_ where the last decoded character starts.
        size_t lastDecodedBufferOffset_ = 0;
        // Offset, relative to charIndex_, of the last decoded character,
        // in code points, not chars.
        size_t lastDecodedCharOffset_ = 0;

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
        this(void[] buffer) @trusted pure //!nothrow
        {
            auto endianResult = fixUTFByteOrder(cast(ubyte[])buffer);
            if(endianResult.bytesStripped > 0)
            {
                throw new ReaderException("Size of UTF-16 or UTF-32 input not aligned "
                                          "to 2 or 4 bytes, respectively");
            }

            auto utf8Result = toUTF8(endianResult.array, endianResult.encoding);

            buffer_ = utf8Result.utf8;
            //buffer_ = buffer;

            characterCount_ = utf8Result.characterCount;
            //characterCount_ = buffer.length;

            checkASCII();
        }
        private this() @safe {

        }
        /// Optimized version of peek() for the case where peek index is 0.
        dchar front() @safe
        {
            if(upcomingASCII_ > 0)            { return buffer_[bufferOffset_]; }
            if(characterCount_ <= charIndex_) { return '\0'; }

            lastDecodedCharOffset_   = 0;
            lastDecodedBufferOffset_ = bufferOffset_;
            return decodeNext();
        }

        ///Returns a copy
        Reader save() @safe {
            auto output = new Reader();
            output.buffer_ = buffer_;
            output.bufferOffset_ = bufferOffset_;
            output.charIndex_ = charIndex_;
            output.characterCount_ = characterCount_;
            output.line_ = line_;
            output.column_ = column_;
            output.upcomingASCII_ = upcomingASCII_;
            output.lastDecodedBufferOffset_ = lastDecodedBufferOffset_;
            output.lastDecodedCharOffset_ = lastDecodedCharOffset_;
            return output;
        }

        bool empty() @safe const {
            return characterCount_ <= charIndex_;
        }

        /// Move current position forward by one character.
        void popFront() @trusted
        {
            ++charIndex_;
            lastDecodedBufferOffset_ = bufferOffset_;
            lastDecodedCharOffset_ = 0;

            // ASCII
            if(upcomingASCII_ > 0)
            {
                --upcomingASCII_;
                const c = buffer_[bufferOffset_++];

                if(c == '\n' || (c == '\r' && buffer_[bufferOffset_] != '\n'))
                {
                    ++line_;
                    column_ = 0;
                    return;
                }
                ++column_;
                return;
            }

            const c = decode(buffer_, bufferOffset_);

            // New line. (can compare with '\n' without decoding since it's ASCII)
            if(c.among!('\n', '\u0085', '\u2028', '\u2029') || (c == '\r' && buffer_[bufferOffset_] != '\n'))
            {
                ++line_;
                column_ = 0;
            }
            else if(c != '\uFEFF') { ++column_; }

            checkASCII();
        }

@safe pure:
        /// Get a string describing current buffer position, used for error messages.
        Mark mark() @nogc nothrow const { return Mark(line_, column_); }

        /// Get current line number.
        uint line() const { return line_; }

        /// Get current column number.
        uint column() const { return column_; }

private:
        // Update upcomingASCII_ (should be called forward()ing over a UTF-8 sequence)
        void checkASCII()
        {
            upcomingASCII_ = countASCII(buffer_[bufferOffset_ .. $]);
        }

        // Decode the next character relative to
        // lastDecodedCharOffset_/lastDecodedBufferOffset_ and update them.
        //
        // Does not advance the buffer position. Used in peek() and slice().
        dchar decodeNext()
        {
            assert(lastDecodedBufferOffset_ < buffer_.length,
                   "Attempted to decode past the end of YAML buffer");
            const char b = buffer_[lastDecodedBufferOffset_];
            ++lastDecodedCharOffset_;
            // ASCII
            if(b < 0x80)
            {
                ++lastDecodedBufferOffset_;
                return b;
            }

            return decode(buffer_, lastDecodedBufferOffset_);
        }
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
auto toUTF8(ubyte[] input, const UTFEncoding encoding) @safe pure nothrow
{
    // Documented in function ddoc.
    struct Result
    {
        string errorMessage;
        char[] utf8;
        size_t characterCount;
    }

    Result result;

    // Encode input_ into UTF-8 if it's encoded as UTF-16 or UTF-32.
    //
    // Params:
    //
    // buffer = The input buffer to encode.
    // result = A Result struct to put encoded result and any error messages to.
    //
    // On error, result.errorMessage will be set.
    static void encode(C)(C[] input, ref Result result) @safe pure
    {
        // We can do UTF-32->UTF-8 in place because all UTF-8 sequences are 4 or
        // less bytes.
        static if(is(C == dchar))
        {
            char[4] encodeBuf;
            auto utf8 = cast(char[])input;
            auto length = 0;
            foreach(dchar c; input)
            {
                ++result.characterCount;
                // ASCII
                if(c < 0x80)
                {
                    utf8[length++] = cast(char)c;
                    continue;
                }

                const encodeResult = std.utf.encode(encodeBuf, c);
                utf8[length .. length + encodeResult] = encodeBuf[0 .. encodeResult];
                length += encodeResult;
            }
            result.utf8 = utf8[0 .. length];
        }
        // Unfortunately we can't do UTF-16 in place so we just use std.conv.to
        else
        {
            result.characterCount = std.utf.count(input);
            result.utf8 = input.to!(char[]);
        }
    }

    try final switch(encoding)
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
    catch(ConvException e) { result.errorMessage = e.msg; }
    catch(UTFException e)  { result.errorMessage = e.msg; }
    catch(Exception e)
    {
        assert(false, "Unexpected exception in encode(): " ~ e.msg);
    }

    return result;
}

/// Determine if all characters (code points, not bytes) in a string are printable.
bool isPrintableValidUTF8(const char[] chars) @trusted pure nothrow @nogc
{
    // This is oversized (only 128 entries are necessary) simply because having 256
    // entries improves performance... for some reason (alignment?)
    bool[256] printable = [false, false, false, false, false, false, false, false,
                           false, true,  true,  false, false, true,  false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,

                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,

                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,
                           true,  true,  true,  true, true,  true,  true,  true,

                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,

                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false,
                           false, false, false, false, false, false, false, false];

    for(size_t index = 0; index < chars.length;)
    {
        // Fast path for ASCII.
        // Both this while() block and the if() block below it are optimized, unrolled
        // versions of the for() block below them; the while()/if() block could be
        // removed without affecting logic, but both help increase performance.
        size_t asciiCount = countASCII(chars[index .. $]);
        // 8 ASCII iterations unrolled, looping while there are at most 8 ASCII chars.
        while(asciiCount > 8)
        {
            const dchar b0 = chars[index];
            const dchar b1 = chars[index + 1];
            const dchar b2 = chars[index + 2];
            const dchar b3 = chars[index + 3];
            const dchar b4 = chars[index + 4];
            const dchar b5 = chars[index + 5];
            const dchar b6 = chars[index + 6];
            const dchar b7 = chars[index + 7];

            index += 8;
            asciiCount -= 8;

            const all = printable[b0] & printable[b1] & printable[b2] & printable[b3] &
                        printable[b4] & printable[b5] & printable[b6] & printable[b1];
            if(!all)
            {
                return false;
            }
        }
        // 4 ASCII iterations unrolled
        if(asciiCount > 4)
        {
            const char b0 = chars[index];
            const char b1 = chars[index + 1];
            const char b2 = chars[index + 2];
            const char b3 = chars[index + 3];

            index += 4;
            asciiCount -= 4;

            if(!printable[b0]) { return false; }
            if(!printable[b1]) { return false; }
            if(!printable[b2]) { return false; }
            if(!printable[b3]) { return false; }
        }
        // Any remaining ASCII chars. This is really the only code needed to handle
        // ASCII, the above if() and while() blocks are just an optimization.
        for(; asciiCount > 0; --asciiCount)
        {
            const char b = chars[index];
            ++index;
            if(b >= 0x20)    { continue; }
            if(printable[b]) { continue; }
            return false;
        }

        if(index == chars.length) { break; }
        index++;
    }
    return true;
}

/// Counts the number of ASCII characters in buffer until the first UTF-8 sequence.
///
/// Used to determine how many characters we can process without decoding.
size_t countASCII(const(char)[] buffer) @trusted pure nothrow @nogc
{
    size_t count = 0;

    // The topmost bit in ASCII characters is always 0
    enum ulong Mask8  = 0x7f7f7f7f7f7f7f7f;
    enum uint Mask4   = 0x7f7f7f7f;
    enum ushort Mask2 = 0x7f7f;

    // Start by checking in 8-byte chunks.
    while(buffer.length >= Mask8.sizeof)
    {
        const block  = *cast(typeof(Mask8)*)buffer.ptr;
        const masked = Mask8 & block;
        if(masked != block) { break; }
        count += Mask8.sizeof;
        buffer = buffer[Mask8.sizeof .. $];
    }

    // If 8 bytes didn't match, try 4, 2 bytes.
    import std.typetuple;
    foreach(Mask; TypeTuple!(Mask4, Mask2))
    {
        if(buffer.length < Mask.sizeof) { continue; }
        const block  = *cast(typeof(Mask)*)buffer.ptr;
        const masked = Mask & block;
        if(masked != block) { continue; }
        count += Mask.sizeof;
        buffer = buffer[Mask.sizeof .. $];
    }

    // If even a 2-byte chunk didn't match, test just one byte.
    if(buffer.empty || buffer[0] >= 0x80) { return count; }
    ++count;

    return count;
}
// Unittests.

void testEndian(R)()
{
    writeln(typeid(R).toString() ~ ": endian unittest");
    void endian_test(char[] data, Encoding encoding_expected, Endian endian_expected)
    {
        auto reader = new R(data);
        //assert(reader.encoding == encoding_expected);
        //assert(reader.endian_ == endian_expected);
    }
    ubyte[] little_endian_utf_16 = [0xFF, 0xFE, 0x7A, 0x00];
    ubyte[] big_endian_utf_16 = [0xFE, 0xFF, 0x00, 0x7A];
    endian_test(little_endian_utf_16, Encoding.UTF_16, Endian.littleEndian);
    endian_test(big_endian_utf_16, Encoding.UTF_16, Endian.bigEndian);
}

void testPeekPrefixForward(R)()
{
    writeln(typeid(R).toString() ~ ": peek/prefix/forward unittest");
    char[] data = "data".dup;
    auto reader = new R(data);
    assert(reader.save().startsWith("data"));
    reader.popFrontN(2);
}

void testUTF(R)()
{
    writeln(typeid(R).toString() ~ ": UTF formats unittest");
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
    writeln(typeid(R).toString() ~ ": 1 byte file unittest");
    char[] data = [97];

    auto reader = new R(data);
    assert(reader.front == 'a');
    reader.popFront();
    assert(reader.empty);
}

unittest
{
    //testEndian!Reader();
    testPeekPrefixForward!Reader();
    testUTF!Reader();
    test1Byte!Reader();
}

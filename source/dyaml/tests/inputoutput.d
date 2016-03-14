
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.inputoutput;


version(unittest)
{

import std.array;
import std.file;
import std.system;
import std.bitmanip;

import dyaml.tests.common;


alias std.system.endian endian;

/// Get an UTF-16 byte order mark.
///
/// Params:  wrong = Get the incorrect BOM for this system.
///
/// Returns: UTF-16 byte order mark.
wchar bom16(bool wrong = false) pure
{
    wchar bom = cast(wchar)0xFFFE;
    if (!wrong)
        return bom.swapEndian();
    return bom;
}
unittest {
    import std.string;
    auto val = bom16();
    assert(bom16(true) == val.swapEndian);
    if (endian == Endian.bigEndian)
        assert(cast(ubyte[])[val].representation == cast(ubyte[])[0xFE, 0xFF]);
    else
        assert(cast(ubyte[])[val].representation == cast(ubyte[])[0xFF, 0xFE]);
}
/// Get an UTF-32 byte order mark.
///
/// Params:  wrong = Get the incorrect BOM for this system.
///
/// Returns: UTF-32 byte order mark.
dchar bom32(bool wrong = false) pure
{
    dchar bom = cast(dchar)0xFFFE0000;
    if (!wrong)
        return bom.swapEndian();
    return bom;
}
unittest {
    import std.string;
    auto val = bom32();
    assert(bom32(true) == val.swapEndian);
    if (endian == Endian.bigEndian)
        assert(cast(ubyte[])[val].representation == cast(ubyte[])[0x00, 0x00, 0xFE, 0xFF]);
    else
        assert(cast(ubyte[])[val].representation == cast(ubyte[])[0xFF, 0xFE, 0x00, 0x00]);
}

/// Unicode input unittest. Tests various encodings.
///
/// Params:  verbose         = Print verbose output?
///          unicodeFilename = File name to read from.
void testUnicodeInput(bool verbose, string unicodeFilename)
{
    string data     = readText(unicodeFilename);
    string expected = data.split().join(" ");

    Node output = Loader(cast(void[])data.to!(char[])).load();
    assert(output.as!string == expected);

    foreach(buffer; [cast(void[])(bom16() ~ data.to!(wchar[])),
                     cast(void[])(bom32() ~ data.to!(dchar[]))])
    {
        output = Loader(buffer).load();
        assert(output.as!string == expected);
    }
}

/// Unicode input error unittest. Tests various encodings with incorrect BOMs.
///
/// Params:  verbose         = Print verbose output?
///          unicodeFilename = File name to read from.
void testUnicodeInputErrors(bool verbose, string unicodeFilename)
{
    string data = readText(unicodeFilename);
    foreach(buffer; [cast(void[])(data.to!(wchar[])),
                     cast(void[])(data.to!(dchar[])),
                     cast(void[])(bom16(true) ~ data.to!(wchar[])),
                     cast(void[])(bom32(true) ~ data.to!(dchar[]))])
    {
        try { Loader(buffer).load(); }
        catch(YAMLException e)
        {
            if(verbose) { writeln(typeid(e).toString(), "\n", e); }
            continue;
        }
        assert(false, "Expected an exception");
    }
}


unittest
{
    writeln("D:YAML I/O unittest");
    run("testUnicodeInput", &testUnicodeInput, ["unicode"]);
    run("testUnicodeInputErrors", &testUnicodeInputErrors, ["unicode"]);
}

} // version(unittest)

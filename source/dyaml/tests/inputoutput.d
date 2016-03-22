
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.inputoutput;


version(unittest)
{

import std.array;
import std.meta;

import dyaml.tests.common;


/// Unicode input unittest. Tests various encodings.
///
/// Params:  verbose         = Print verbose output?
///          unicodeFilename = File name to read from.
void testUnicodeInput(bool verbose, string unicodeFilename)
{
    auto data     = readText!(char[])(unicodeFilename);
    auto expected = data.split().join(" ");

    Node output = Loader(data).load();
    assert(output.as!string == expected);

    //foreach(buffer; [cast(void[])(bom16() ~ data.to!(wchar[])),
    //                 cast(void[])(bom32() ~ data.to!(dchar[]))])
    //{
    //    output = Loader(buffer).load();
    //    assert(output.as!string == expected);
    //}
}


unittest
{
    writeln("D:YAML I/O unittest");
    run("testUnicodeInput", &testUnicodeInput, ["unicode"]);
}

} // version(unittest)

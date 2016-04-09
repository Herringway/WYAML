
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.inputoutput;


version(unittest)
{

import std.array;
import std.meta;
import std.utf;

import wyaml.tests.common;


/// Unicode input unittest. Tests various encodings.
///
/// Params:  unicodeFilename = File name to read from.
void testUnicodeInput(string unicodeFilename)
{
    auto data     = readText(unicodeFilename);
    auto expected = data.split().join(" ");

    Node output = Loader(data).load();
    assert(output.as!string == expected);
}


unittest
{
    writeln("D:YAML I/O unittest");
    run("testUnicodeInput", &testUnicodeInput, ["unicode"]);
}

} // version(unittest)


//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.reader;


version(unittest)
{

import wyaml.tests.common;
import wyaml.reader;
import std.algorithm;


// Try reading entire file through Reader, expecting an error (the file is invalid).
//
// Params:  verbose = Print verbose output?
//          data    = Stream to read.
void testStreamError(bool verbose, string fileName)
{
    try
    {
        auto reader = new Reader(cast(char[])std.file.read(fileName));
        while(!reader.empty) { reader.popFront(); }
        //assert(false, "Expected an exception: "~fileName);
    }
    catch(ReaderException e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
    }
}

unittest
{
    writeln("D:YAML Reader unittest");
    run("testStreamError", &testStreamError, ["stream-error"]);
}

} // version(unittest)

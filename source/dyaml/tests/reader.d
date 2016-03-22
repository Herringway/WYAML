
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.reader;


version(unittest)
{

import dyaml.tests.common;
import dyaml.reader;
import std.algorithm;


// Try reading entire file through Reader, expecting an error (the file is invalid).
//
// Params:  verbose = Print verbose output?
//          data    = Stream to read.
void runReader(const bool verbose, char[] fileData)
{
    try
    {
        auto reader = new Reader(fileData);
        while(reader.front != '\0') { reader.popFront(); }
        assert(false, "Expected an exception");
    }
    catch(ReaderException e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
    }
}


/// Stream error unittest. Tries to read invalid input files, expecting errors.
///
/// Params:  verbose       = Print verbose output?
///          errorFilename = File name to read from.
void testStreamError(bool verbose, string errorFilename)
{
    import std.file;
    runReader(verbose, cast(char[])std.file.read(errorFilename));
}

unittest
{
    writeln("D:YAML Reader unittest");
    run("testStreamError", &testStreamError, ["stream-error"]);
}

} // version(unittest)

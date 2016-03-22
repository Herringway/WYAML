
//          Copyright Ferdinand Majerech 2011-2014
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.errors;


version(unittest)
{

import dyaml.tests.common;


/// Loader error unittest from file stream.
///
/// Params:  verbose       = Print verbose output?
///          errorFilename = File name to read from.
void testLoaderError(bool verbose, string errorFilename)
{
    try {
        char[] buffer = readText!(char[])(errorFilename);

        Node[] nodes;
        nodes = Loader(buffer).loadAll();
    }
    catch(Exception e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "Expected an exception");
}

/// Loader error unittest from string.
///
/// Params:  verbose       = Print verbose output?
///          errorFilename = File name to read from.
void testLoaderErrorString(bool verbose, string errorFilename)
{
    // Load file to a buffer, then pass that to the YAML loader.

    try
    {
        auto buffer = readText!(char[])(errorFilename);
        auto nodes = Loader(buffer).loadAll();
    }
    catch(Exception e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "Expected an exception");
}

/// Loader error unittest from filename.
///
/// Params:  verbose       = Print verbose output?
///          errorFilename = File name to read from.
void testLoaderErrorFilename(bool verbose, string errorFilename)
{
    try { auto nodes = Loader(readText!(char[])(errorFilename)).loadAll(); }
    catch(Exception e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "testLoaderErrorSingle(" ~ verbose.to!string ~
                  ", " ~ errorFilename ~ ") Expected an exception");
}

/// Loader error unittest loading a single document from a file.
///
/// Params:  verbose       = Print verbose output?
///          errorFilename = File name to read from.
void testLoaderErrorSingle(bool verbose, string errorFilename)
{
    try { auto nodes = Loader(readText!(char[])(errorFilename)).load(); }
    catch(Exception e)
    {
        if(verbose) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "Expected an exception");
}


unittest
{
    writeln("D:YAML Errors unittest");
    run("testLoaderError",         &testLoaderError,         ["loader-error"]);
    run("testLoaderErrorString",   &testLoaderErrorString,   ["loader-error"]);
    run("testLoaderErrorFilename", &testLoaderErrorFilename, ["loader-error"]);
    run("testLoaderErrorSingle",   &testLoaderErrorSingle,   ["single-loader-error"]);
}

} // version(unittest)

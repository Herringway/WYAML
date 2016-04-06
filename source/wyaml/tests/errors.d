
//          Copyright Ferdinand Majerech 2011-2014
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.errors;


version(unittest)
{

import std.array;

import wyaml.tests.common;


/// Loader error unittest from file stream.
///
/// Params:  errorFilename = File name to read from.
void testLoaderError(string errorFilename)
{
    try {
        char[] buffer = readText!(char[])(errorFilename);

        Node[] nodes;
        nodes = Loader(buffer).loadAll().array;
    }
    catch(Exception e)
    {
        version(verboseTest) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "Expected an exception");
}

/// Loader error unittest from string.
///
/// Params:  errorFilename = File name to read from.
void testLoaderErrorString(string errorFilename)
{
    // Load file to a buffer, then pass that to the YAML loader.

    try
    {
        auto buffer = readText!(char[])(errorFilename);
        auto nodes = Loader(buffer).loadAll().array;
    }
    catch(Exception e)
    {
        version(verboseTest) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "Expected an exception");
}

/// Loader error unittest from filename.
///
/// Params:  errorFilename = File name to read from.
void testLoaderErrorFilename(string errorFilename)
{
    try { auto nodes = Loader(readText!(char[])(errorFilename)).loadAll().array; }
    catch(Exception e)
    {
        version(verboseTest) { writeln(typeid(e).toString(), "\n", e); }
        return;
    }
    assert(false, "testLoaderErrorSingle(" ~ errorFilename ~ ") Expected an exception");
}

/// Loader error unittest loading a single document from a file.
///
/// Params:  errorFilename = File name to read from.
void testLoaderErrorSingle(string errorFilename)
{
    try { auto nodes = Loader(readText!(char[])(errorFilename)).load(); }
    catch(Exception e)
    {
        version(verboseTest) { writeln(typeid(e).toString(), "\n", e); }
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

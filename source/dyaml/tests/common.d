
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.common;

version(unittest)
{

public import std.conv;
public import std.stdio;
public import dyaml;

import core.exception;
import std.algorithm;
import std.array;
import std.bitmanip;
import std.conv;
import std.file;
import std.path;
import std.string;
import std.system;
import std.typecons;
import std.utf;

package:

/**
 * Run an unittest.
 *
 * Params:  testName     = Name of the unittest.
 *          testFunction = Unittest function.
 *          unittestExt  = Extensions of data files needed for the unittest.
 *          skipExt      = Extensions that must not be used for the unittest.
 */
void run(F ...)(string testName, void function(bool, F) testFunction,
                string[] unittestExt, string[] skipExt = [])
{
    immutable string dataDir = "test/data";
    auto testFilenames = findTestFilenames(dataDir);
    bool verbose = false;
    version(verboseTest) verbose = true;

    Result[] results;
    if(unittestExt.length > 0)
    {
        outer: foreach(base, extensions; testFilenames)
        {
            string[] filenames;
            foreach(ext; unittestExt)
            {
                if(!extensions.canFind(ext)){continue outer;}
                filenames ~= base ~ '.' ~ ext;
            }
            foreach(ext; skipExt)
            {
                if(extensions.canFind(ext)){continue outer;}
            }

            results ~= execute!F(testName, testFunction, filenames, verbose);
        }
    }
    else
    {
        results ~= execute!F(testName, testFunction, cast(string[])[], verbose);
    }
    display(results, verbose);
}

T readText(T = char[])(string path) out(result) {
    validate(result);
} body {
    import std.range;
    auto buf = read(path);
    if ((cast(ubyte[])buf).startsWith(cast(ubyte[])[bom16].representation)) {
        return (cast(wchar[])buf).to!T;
    } else if ((cast(ubyte[])buf).startsWith(cast(ubyte[])[bom16(true)].representation)) {
        foreach (ref character; (cast(wchar[])buf))
            character = character.swapEndian();
        return (cast(wchar[])buf).to!T;
    } else if ((cast(ubyte[])buf).startsWith(cast(ubyte[])[bom32].representation)) {
        return (cast(dchar[])buf).to!T;
    } else if ((cast(ubyte[])buf).startsWith(cast(ubyte[])[bom32(true)].representation)) {
        foreach (ref character; (cast(dchar[])buf))
            character = character.swapEndian();
        return (cast(dchar[])buf).to!T;
    }
    return (cast(char[])buf).to!T;
    //try {
    //    return std.file.readText!T(path);
    //} catch (std.utf.UTFException) {
    //    auto buffer = cast(T)std.file.read(path);
    //    foreach (ref character; buffer)
    //        character = character.swapEndian();
    //    buffer.validate();
    //    return buffer;
    //}
}

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
private:

///Unittest status.
enum TestStatus
{
    Success, //Unittest passed.
    Failure, //Unittest failed.
    Error    //There's an error in the unittest.
}

///Unittest result.
alias Tuple!(string, "name", string[], "filenames", TestStatus, "kind", string, "info") Result;

/**
 * Find unittest input filenames.
 *
 * Params:  dir = Directory to look in.
 *
 * Returns: Test input base filenames and their extensions.
 */
string[][string] findTestFilenames(const string dir)
{
    //Groups of extensions indexed by base names.
    string[][string] names;
    foreach(string name; dirEntries(dir, SpanMode.shallow))
    {
        if(isFile(name))
        {
            string base = name.stripExtension();
            string ext  = name.extension();
            if(ext is null){ext = "";}
            if(ext[0] == '.'){ext = ext[1 .. $];}

            //If the base name doesn't exist yet, add it; otherwise add new extension.
            names[base] = ((base in names) is null) ? [ext] : names[base] ~ ext;
        }
    }
    return names;
}

/**
 * Recursively copy an array of strings to a tuple to use for unittest function input.
 *
 * Params:  index   = Current index in the array/tuple.
 *          tuple   = Tuple to copy to.
 *          strings = Strings to copy.
 */
void stringsToTuple(uint index, F ...)(ref F tuple, const string[] strings)
in{assert(F.length == strings.length);}
body
{
    tuple[index] = strings[index];
    static if(index > 0){stringsToTuple!(index - 1, F)(tuple, strings);}
}

/**
 * Execute an unittest on specified files.
 *
 * Params:  testName     = Name of the unittest.
 *          testFunction = Unittest function.
 *          filenames    = Names of input files to test with.
 *          verbose      = Print verbose output?
 *
 * Returns: Information about the results of the unittest.
 */
Result execute(F ...)(const string testName, void function(bool, F) testFunction,
                      string[] filenames, const bool verbose)
{
    if(verbose)
    {
        writeln("===========================================================================");
        writeln(testName ~ "(" ~ filenames.join(", ") ~ ")...");
    }

    auto kind = TestStatus.Success;
    string info = "";
    try
    {
        //Convert filenames to parameters tuple and call the test function.
        F parameters;
        stringsToTuple!(F.length - 1, F)(parameters, filenames);
        testFunction(verbose, parameters);
        if(!verbose){write(".");}
    }
    catch(Throwable e)
    {
        info = to!string(typeid(e)) ~ "\n" ~ to!string(e);
        kind = (typeid(e) is typeid(AssertError)) ? TestStatus.Failure : TestStatus.Error;
        write((verbose ? to!string(e) : to!string(kind)) ~ " ");
    }

    stdout.flush();

    return Result(testName, filenames, kind, info);
}

/**
 * Display unittest results.
 *
 * Params:  results = Unittest results.
 *          verbose = Print verbose output?
 */
void display(Result[] results, const bool verbose)
{
    if(results.length > 0 && !verbose){write("\n");}

    size_t failures = 0;
    size_t errors = 0;

    if(verbose)
    {
        writeln("===========================================================================");
    }
    //Results of each test.
    foreach(result; results)
    {
        if(verbose)
        {
            writeln(result.name, "(" ~ result.filenames.join(", ") ~ "): ",
                    to!string(result.kind));
        }

        if(result.kind == TestStatus.Success){continue;}

        if(result.kind == TestStatus.Failure){++failures;}
        else if(result.kind == TestStatus.Error){++errors;}
        writeln(result.info);
        writeln("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~");
    }

    //Totals.
    writeln("===========================================================================");
    writeln("TESTS: ", results.length);
    if(failures > 0){writeln("FAILURES: ", failures);}
    if(errors > 0)  {writeln("ERRORS: ", errors);}
}
} // version(unittest)

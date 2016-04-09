
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.compare;


version(unittest)
{
import std.range;
import wyaml.tests.common;
import wyaml.token;

/// Test parser by comparing output from parsing two equivalent YAML files.
///
/// Params:  verbose           = Print verbose output?
///          dataFilename      = YAML file to parse.
///          canonicalFilename = Another file to parse, in canonical YAML format.
void testParser(string dataFilename, string canonicalFilename)
{
    auto dataEvents = Loader(readText(dataFilename)).parse();
    auto canonicalEvents = Loader(readText(canonicalFilename)).parse();

    foreach(test, canon; lockstep(dataEvents, canonicalEvents, StoppingPolicy.requireSameLength))
    {
        assert(test.id == canon.id);
    }
}


/// Test loader by comparing output from loading two equivalent YAML files.
///
/// Params:  verbose           = Print verbose output?
///          dataFilename      = YAML file to load.
///          canonicalFilename = Another file to load, in canonical YAML format.
void testLoader(string dataFilename, string canonicalFilename)
{
    auto data = Loader(readText(dataFilename)).loadAll();
    auto canonical = Loader(readText(canonicalFilename)).loadAll();

    foreach(test, canon; lockstep(data, canonical, StoppingPolicy.requireSameLength))
    {
        scope(failure)
            writeComparison(canon, test);
        assert(test == canon, "testLoader(" ~ dataFilename ~ ", " ~ canonicalFilename ~ ") failed");
    }
}


unittest
{
    writeln("D:YAML comparison unittest");
    run("testParser", &testParser, ["data", "canonical"]);
    run("testLoader", &testLoader, ["data", "canonical"], ["test_loader_skip"]);
}

} // version(unittest)

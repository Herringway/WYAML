
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module dyaml.tests.resolver;


version(unittest)
{

import std.string;

import dyaml.tests.common;


/**
 * Implicit tag resolution unittest.
 *
 * Params:  verbose        = Print verbose output?
 *          dataFilename   = File with unittest data.
 *          detectFilename = Dummy filename used to specify which data filenames to use.
 */
void testImplicitResolver(bool verbose, string dataFilename, string detectFilename)
{
    char[] correctTag;
    Node node;

    scope(failure)
    {
        if(true)
        {
            writeln("Correct tag: ", correctTag);
            writeln("Node: ", node.debugString);
        }
    }

    correctTag = readText(detectFilename).strip();
    node = Loader(readText!(char[])(dataFilename)).load();
    assert(node.isSequence);
    foreach(ref Node scalar; node)
    {
        assert(scalar.isScalar);
        assert(scalar.tag == correctTag);
    }
}


unittest
{
    writeln("D:YAML Resolver unittest");
    run("testImplicitResolver", &testImplicitResolver, ["data", "detect"]);
}

} // version(unittest)

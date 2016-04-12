
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.tests.representer;


version(unittest)
{

import std.array;
import std.exception;
import std.outbuffer;
import std.path;
import std.range;
import std.typecons;

import wyaml.tests.common;
import wyaml.tests.constructor;


/// Representer unittest.
///
/// Params:  codeFilename = File name to determine test case from.
///                         Nothing is read from this file, it only exists
///                         to specify that we need a matching unittest.
void testRepresenterTypes(string codeFilename)
{
    string baseName = codeFilename.baseName.stripExtension;
    enforce((baseName in wyaml.tests.constructor.expected) !is null,
            new Exception("Unimplemented representer test: " ~ baseName));

    Node[] expectedNodes = expected[baseName];
    //foreach(encoding; [Encoding.UTF_8, Encoding.UTF_16, Encoding.UTF_32])
    //{
        string output;
        Node[] readNodes;

        scope(failure)
        {
            version(verboseTest)
            {
                writeln("Expected nodes:");
                foreach(ref n; expectedNodes){writeln(n.debugString, "\n---\n");}
                writeln("Read nodes:");
                foreach(ref n; readNodes){writeln(n.debugString, "\n---\n");}
                writeln("OUTPUT:\n", output);
            }
        }

        auto emitStream  = new OutBuffer;
        auto representer = new Representer;
        representer.addRepresenter!TestClass(&representClass);
        representer.addRepresenter!TestStruct(&representStruct);
        auto dumper = dumper(emitStream);
        dumper.representer = representer;
        dumper.dump(expectedNodes);

        output = emitStream.toString;
        auto constructor = new Constructor;
        constructor.addConstructorMapping!constructClass("!tag1");
        constructor.addConstructorScalar!constructStruct("!tag2");

        auto loader        = Loader(emitStream.toString().dup);
        loader.name        = "TEST";
        loader.constructor = constructor;
        readNodes          = loader.loadAll().array;

        foreach(expected, read; lockstep(expectedNodes, readNodes, StoppingPolicy.requireSameLength))
        {
            assert(expected.equals!(No.useTag)(read));
        }
    //}
}

unittest
{
    writeln("D:YAML Representer unittest");
    run("testRepresenterTypes", &testRepresenterTypes, ["code"]);
}

} // version(unittest)

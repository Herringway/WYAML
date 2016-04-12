
///Random YAML generator. Used to generate benchmarking inputs.

import std.algorithm;
import std.conv;
import std.datetime;
import std.math;
import std.random;
import std.stdio;
import std.string;
import wyaml;


Node config;
Node function(bool)[string] generators;
auto typesScalar     = ["string", "int", "float", "bool", "timestamp", "binary"];
auto typesScalarKey  = ["string", "int", "float", "timestamp"];
auto typesCollection = ["map","omap", "pairs", "seq", "set"];
ulong minNodesDocument;
ulong totalNodes;

static this()
{
    generators["string"]    = &genString;
    generators["int"]       = &genInt;
    generators["float"]     = &genFloat;
    generators["bool"]      = &genBool;
    generators["timestamp"] = &genTimestamp;
    generators["binary"]    = &genBinary;
    generators["map"]       = &genMap;
    generators["omap"]      = &genOmap;
    generators["pairs"]     = &genPairs;
    generators["seq"]       = &genSeq;
    generators["set"]       = &genSet;
}

T distribute(T)(T input, in string distribution = "linear") {
    switch(distribution)
    {
        case "linear":
            return input;
        case "quadratic":
            return input^^2;
        case "cubic":
            return input^^3;
        default:
            writeln("Unknown random distribution: ", distribution,
                    ", falling back to linear");
            return input.distribute("linear");
    }
}

string randomType(string[] types)
{
    auto probabilities = new uint[types.length];
    foreach(index, type; types)
    {
        probabilities[index] = config[type]["probability"].as!uint;
    }
    return types[dice(probabilities)];
}

Node genString(bool root = false)
{
    auto range = config["string"]["range"];

    auto alphabet = config["string"]["alphabet"].as!dstring;

    const chars = uniform(range["min"].as!size_t, range["max"].as!size_t).distribute(range["dist"].as!string);

    dchar[] result = new dchar[chars];
    foreach (ref c; result)
        c = alphabet.randomSample(1).front;
    //result[0] = randomChar(alphabet);
    //foreach(i; 1 .. chars)
    //{
    //    result[i] = randomChar(alphabet);
    //}

    return Node(result.to!string);
}

Node genInt(bool root = false)
{
    auto range = config["int"]["range"];

    const result = uniform(range["min"].as!int, range["max"].as!int).distribute(range["dist"].as!string);

    return Node(result);
}

Node genFloat(bool root = false)
{
    auto range = config["float"]["range"];

    const result = uniform(range["min"].as!real, range["max"].as!real).distribute(range["dist"].as!string);

    return Node(result);
}

Node genBool(bool root = false)
{
    return Node(uniform(0, 1) ? true : false);
}

Node genTimestamp(bool root = false)
{
    auto range = config["timestamp"]["range"];

    auto hnsecs = uniform(range["min"].as!ulong, range["max"].as!ulong).distribute(range["dist"].as!string);

    if(uniform(0.0L, 1.0L) <= config["timestamp"]["round-chance"].as!real)
    {
        hnsecs -= hnsecs % 10000000;
    }

    return Node(SysTime(hnsecs));
}

Node genBinary(bool root = false)
{
    auto range = config["binary"]["range"];

    const bytes = uniform(range["min"].as!uint, range["max"].as!uint).distribute(range["dist"].as!string);

    ubyte[] result = new ubyte[bytes];
    foreach(i; 0 .. bytes)
    {
        result[i] = uniform!ubyte();
    }

    return Node(result);
}

Node nodes(const bool root, Node range, const string tag, const bool set = false)
{
    auto types = config["collection-keys"].as!bool ? typesCollection : [];
    types ~= (set ? typesScalarKey : typesScalar);

    Node[] nodes;
    if(root)
    {
        while(!(totalNodes >= minNodesDocument))
        {
            nodes.assumeSafeAppend;
            nodes ~= generateNode(randomType(types));
        }
    }
    else
    {
        const elems = uniform(range["min"].as!uint, range["max"].as!uint).distribute(range["dist"].as!string);

        nodes = new Node[elems];
        foreach(i; 0 .. elems)
        {
            nodes[i] = generateNode(randomType(types));
        }
    }

    return Node(nodes, tag);
}

Node genSeq(bool root = false)
{
    return nodes(root, config["seq"]["range"], "tag:yaml.org,2002:seq");
}

Node genSet(bool root = false)
{
    return nodes(root, config["seq"]["range"], "tag:yaml.org,2002:set", true);
}

Node pairs(bool root, bool complex, Node range, string tag)
{
    Node[] keys, values;

    if(root)
    {
        while(!(totalNodes >= minNodesDocument))
        {
            const key = generateNode(randomType(typesScalarKey ~ (complex ? typesCollection : [])));
            // Maps can't contain duplicate keys
            if(tag.endsWith("map") && keys.canFind(key)) { continue; }
            keys.assumeSafeAppend;
            values.assumeSafeAppend;
            keys ~= key;
            values ~= generateNode(randomType(typesScalar ~ typesCollection));
        }
    }
    else
    {
        const pairs = uniform(range["min"].as!uint, range["max"].as!uint).distribute(range["dist"].as!string);

        keys = new Node[pairs];
        values = new Node[pairs];
        foreach(i; 0 .. pairs)
        {
            auto key = generateNode(randomType(typesScalarKey ~ (complex ? typesCollection : [])));
            // Maps can't contain duplicate keys
            while(tag.endsWith("map") && keys[0 .. i].canFind(key))
            {
                key = generateNode(randomType(typesScalarKey ~ (complex ? typesCollection : [])));
            }
            keys[i]   = key;
            values[i] = generateNode(randomType(typesScalar ~ typesCollection));
        }
    }

    return Node(keys, values, tag);
}

Node genMap(bool root = false)
{
    Node range = config["map"]["range"];
    const complex = config["complex-keys"].as!bool;

    return pairs(root, complex, range, "tag:yaml.org,2002:map");
}

Node genOmap(bool root = false)
{
    Node range = config["omap"]["range"];
    const complex = config["complex-keys"].as!bool;

    return pairs(root, complex, range, "tag:yaml.org,2002:omap");
}

Node genPairs(bool root = false)
{
    Node range = config["pairs"]["range"];
    const complex = config["complex-keys"].as!bool;

    return pairs(root, complex, range, "tag:yaml.org,2002:pairs");
}

Node generateNode(const string type, bool root = false)
{
    ++totalNodes;
    return generators[type](root);
}

Node[] generate(const string configFileName)
{
    import std.file : readText;
    config = loader(readText(configFileName)).load();

    minNodesDocument = config["min-nodes-per-document"].as!long;

    Node[] result = new Node[](config["documents"].as!uint);
    foreach(ref doc; result)
    {
        doc = generateNode(config["root-type"].as!string, true);
        totalNodes = 0;
    }

    return result;
}


void main(string[] args)
{
    //Help message.
    if(args.length == 1)
    {
        writeln("Usage: yaml_gen FILE [CONFIG_FILE]\n");
        writeln("Generates a random YAML file and writes it to FILE.");
        writeln("If provided, CONFIG_FILE overrides the default config file.");
        return;
    }

    string configFile = args.length >= 3 ? args[2] : "config.yaml";

    try
    {
        //Generate and dump the nodes.
        Node[] generated = generate(configFile);

        auto dumper     = dumper(File(args[1], "w").lockingTextWriter);

        dumper.indent = config["indent"].as!uint;
        dumper.textWidth = config["text-width"].as!uint;
        dumper.dump(generated);
    }
    catch(YAMLException e)
    {
        writeln("ERROR: ", e);
    }
}


module yaml_bench;
//Benchmark that loads, and optionally extracts data from and/or emits a YAML file.

import std.conv;
import std.datetime;
import std.getopt;
import std.outbuffer;
import std.stdio;
import std.string;
import wyaml;

///Get data out of every node.
void extract(ref Node document)
{
    void crawl(ref Node root)
    {
        if(root.isScalar) switch(root.tag)
        {
            case "tag:yaml.org,2002:null":      auto value = root.as!YAMLNull;  break;
            case "tag:yaml.org,2002:bool":      auto value = root.as!bool;      break;
            case "tag:yaml.org,2002:int":       auto value = root.as!long;      break;
            case "tag:yaml.org,2002:float":     auto value = root.as!real;      break;
            case "tag:yaml.org,2002:binary":    auto value = root.as!(ubyte[]); break;
            case "tag:yaml.org,2002:timestamp": auto value = root.as!SysTime;   break;
            case "tag:yaml.org,2002:str":       auto value = root.as!string;    break;
            default: writeln("Unrecognozed tag: ", root.tag);
        }
        else if(root.isSequence) foreach(ref Node node; root)
        {
            crawl(node);
        }
        else if(root.isMapping) foreach(ref Node key, ref Node value; root)
        {
            crawl(key);
            crawl(value);
        }
    }

    crawl(document);
}

void main(string[] args)
{
    bool get      = false;
    bool dump     = false;
    bool reload   = false;
    uint runs = 1;
    string file = null;

    auto result = getopt(
        args,
        "get|g", "Extract data from the file (using Node.as()).", &get,
        "dump|d", "Dump the loaded data (to YAML_FILE.dump).", &dump,
        "reload", "Reload the file from the disk on every repeat. By default, the file is loaded to memory once and repeatedly parsed from memory.", &reload,
        "runs|r", "Repeat parsing the file NUM times.", &runs,
        );
    if (!result.helpWanted && args.length == 1)
        writeln("\nFile not specified.\n\n");
    if (result.helpWanted || args.length == 1) {
        defaultGetoptPrinter(
        "D:YAML benchmark\n"
        "Copyright (C) 2011-2014 Ferdinand Majerech\n"
        "Copyright (C) 2016 Cameron \"Herringway\" Ross\n"
        "Usage: yaml_bench [OPTION ...] [YAML_FILE]\n"
        "\n"
        "Loads and optionally extracts data and/or dumps a YAML file.\n", result.options);
        return;
    }
    file = args[1];

    try
    {
        import std.file;
        string fileInMemory;
        if(!reload) { fileInMemory = std.file.readText!string(file); }
        string fileWorkingCopy = fileInMemory.dup;

        // Instead of constructing a resolver/constructor with each Loader,
        // construct them once to remove noise when profiling.
        auto resolver    = new Resolver();
        auto constructor = new Constructor();

        while(runs--)
        {
            // Loading the file rewrites the loaded buffer, so if we don't reload from
            // disk, we need to use a copy of the originally loaded file.
            if(reload) { fileInMemory = std.file.readText!string(file); }
            else       { fileWorkingCopy = fileInMemory; }
            string fileToLoad = reload ? fileInMemory : fileWorkingCopy;
            auto loader        = Loader(fileToLoad);
            loader.resolver    = resolver;
            loader.constructor = constructor;
            auto nodes = loader.loadAll();
            if(dump)
            {
                OutBuffer buf;
                dumper(buf).dump(nodes);
            }
            if(get) foreach(ref node; nodes)
            {
                extract(node);
            }
        }
    }
    catch(YAMLException e)
    {
        writeln("ERROR: ", e.msg);
    }
}

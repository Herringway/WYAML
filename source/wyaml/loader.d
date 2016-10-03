//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Class used to load YAML documents.
module wyaml.loader;

import std.array;
import std.exception;
import std.range;
import std.string;
import std.traits;
import std.utf;

import wyaml.composer;
import wyaml.constructor;
import wyaml.event;
import wyaml.exception;
import wyaml.node;
import wyaml.parser;
import wyaml.reader;
import wyaml.resolver;
import wyaml.scanner;
import wyaml.token;

auto loader(T)(T range) if(isInputRange!T && isSomeChar!(ElementType!T)) {
    return Loader(range.array.toUTF8.idup);
}
unittest {
    import std.stdio : File;
    import std.algorithm : joiner;
    assert(__traits(compiles,
        loader("---\n...").loadAll()));
    assert(__traits(compiles,
        loader(File("a", "r").byLineCopy.joiner).loadAll()));
}
/** Loads YAML documents from files or streams.
 *
 * User specified Constructor and/or Resolver can be used to support new
 * tags / data types.
 *
 * Examples:
 *
 * Load single YAML document from a file:
 * --------------------
 * auto rootNode = Loader("file.yaml").load();
 * ...
 * --------------------
 *
 * Load all YAML documents from a file:
 * --------------------
 * auto nodes = Loader("file.yaml").loadAll();
 * ...
 * --------------------
 *
 * Iterate over YAML documents in a file, lazily loading them:
 * --------------------
 * auto loader = Loader("file.yaml");
 *
 * foreach(ref node; loader)
 * {
 *     ...
 * }
 * --------------------
 *
 * Load YAML from a string:
 * --------------------
 * string yaml_input = "red:   '#ff0000'\n"
 *                     "green: '#00ff00'\n"
 *                     "blue:  '#0000ff'";
 *
 * auto colors = loader(yaml_input).load();
 *
 * foreach(string color, string value; colors)
 * {
 *     import std.stdio;
 *     writeln(color, " is ", value, " in HTML/CSS");
 * }
 * --------------------
 *
 * Load a file into a buffer in memory and then load YAML from that buffer:
 * --------------------
 * try
 * {
 *     import std.file;
 *     void[] buffer = std.file.read("file.yaml");
 *     auto yamlNode = Loader(buffer);
 *
 *     // Read data from yamlNode here...
 * }
 * catch(FileException e)
 * {
 *     writeln("Failed to read file 'file.yaml'");
 * }
 * --------------------
 *
 * Use a custom constructor/resolver to support custom data types and/or implicit tags:
 * --------------------
 * auto constructor = new Constructor();
 * auto resolver    = new Resolver();
 *
 * // Add constructor functions / resolver expressions here...
 *
 * auto loader = Loader("file.yaml");
 * loader.constructor = constructor;
 * loader.resolver    = resolver;
 * auto rootNode      = loader.load(node);
 * --------------------
 */
struct Loader
{
    private:
        // Reads character data from a stream.
        Reader reader_;
        // Processes character data to YAML tokens.
        Scanner scanner_;
        // Processes tokens to YAML events.
        Parser parser_;
        // Resolves tags (data types).
        Resolver resolver_;
        // Constructs YAML data types.
        Constructor constructor_;
        // Name of the input file or stream, used in error messages.
        string name_ = "<unknown>";
        // Are we done loading?
        bool done_ = false;

    public:
        @disable this();
        @disable int opCmp(ref Loader);
        @disable bool opEquals(ref Loader);

        /** Construct a Loader to load YAML from a buffer.
         *
         * Params: yamlData = Buffer with YAML data to load. This may be e.g. a file
         *                    loaded to memory or a string with YAML data. Note that
         *                    buffer $(B will) be overwritten, as D:YAML minimizes
         *                    memory allocations by reusing the input _buffer.
         *                    $(B Must not be deleted or modified by the user  as long
         *                    as nodes loaded by this Loader are in use!) - Nodes may
         *                    refer to data in this buffer.
         *
         * Note that D:YAML looks for byte-order-marks YAML files encoded in
         * UTF-16/UTF-32 (and sometimes UTF-8) use to specify the encoding and
         * endianness, so it should be enough to load an entire file to a buffer and
         * pass it to D:YAML, regardless of Unicode encoding.
         *
         * Throws:  YAMLException if yamlData contains data illegal in YAML.
         */
        this(string yamlData)
        {
            try
            {
                reader_      = new Reader(yamlData);
                scanner_     = new Scanner(reader_);
                parser_      = new Parser(scanner_);
            }
            catch(YAMLException e)
            {
                e.msg = "Unable to open %s for YAML loading: %s"
                                        .format(name_, e.msg);
                throw e;
            }
        }

        /// Set stream _name. Used in debugging messages.
        void name(string name) pure @safe nothrow @nogc
        {
            name_ = name;
        }

        /// Specify custom Resolver to use.
        void resolver(Resolver resolver) pure @safe nothrow @nogc
        {
            resolver_ = resolver;
        }

        /// Specify custom Constructor to use.
        void constructor(Constructor constructor) pure @safe nothrow @nogc
        {
            constructor_ = constructor;
        }

        /** Load single YAML document.
         *
         * Returns: Root node of the document.
         *
         * Throws:  YAMLException if there was a YAML parsing error.
         */
        Node load() {
            return loadAll().front;
        }

        /** Load all YAML documents.
         *
         * This is just a shortcut that iterates over all documents and returns them
         * all at once. Calling loadAll after iterating over the node or vice versa
         * will not return any documents, as they have all been parsed already.
         *
         * This can only be called once; this is enforced by contract.
         *
         * Returns: Array of root nodes of all documents in the file/stream.
         *
         * Throws:  YAMLException on a parsing error.
         */
        auto loadAll()
        {
            Node[] nodes;
            foreach(ref node; this)
            {
                nodes.assumeSafeAppend();
                nodes ~= node;
            }
            return nodes;
        }

        /** Foreach over YAML documents.
         *
         * Parses documents lazily, when they are needed.
         *
         * Foreach over a Loader can only be used once; this is enforced by contract.
         *
         * Throws: YAMLException on a parsing error.
         */
        int opApply(int delegate(ref Node) dg)
        in
        {
            assert(!done_, "Loader: Trying to load YAML twice");
        }
        body
        {
            scope(exit) { done_ = true; }
            try
            {
                lazyInitConstructorResolver();
                auto composer = new Composer(parser_, resolver_, constructor_);

                int result = 0;
                while(composer.checkNode())
                {
                    auto node = composer.getNode();
                    result = dg(node);
                    if(result) { break; }
                }

                return result;
            }
            catch(YAMLException e)
            {
                e.msg = "Unable to load YAML from %s : %s "
                                        .format(name_, e.msg);
                throw e;
            }
        }

    package:
        // Scan and return all tokens. Used for debugging.
        Token[] scan()
        {
            try
            {
                Token[] result;
                while(scanner_.checkToken())
                {
                    result.assumeSafeAppend();
                    result ~= scanner_.getToken();
                }
                return result;
            }
            catch(YAMLException e)
            {
                e.msg = "Unable to scan YAML from stream " ~
                                        name_ ~ " : " ~ e.msg;
                throw e;
            }
        }

        // Scan all tokens, throwing them away. Used for benchmarking.
        void scanBench()
        {
            try while(scanner_.checkToken())
            {
                scanner_.getToken();
            }
            catch(YAMLException e)
            {
                e.msg = "Unable to scan YAML from stream " ~
                                        name_ ~ " : " ~ e.msg;
                throw e;
            }
        }


        // Parse and return all events. Used for debugging.
        immutable(Event)[] parse() @safe
        {
            try
            {
                immutable(Event)[] result;
                while(parser_.checkEvent())
                {
                    result ~= parser_.getEvent();
                }
                return result;
            }
            catch(YAMLException e)
            {
                e.msg = "Unable to parse YAML from stream %s : %s "
                                        .format(name_, e.msg);
                throw e;
            }
        }

        // Construct default constructor/resolver if the user has not yet specified
        // their own.
        void lazyInitConstructorResolver() @safe
        {
            if(resolver_ is null)    { resolver_    = new Resolver(); }
            if(constructor_ is null) { constructor_ = new Constructor(); }
        }
}

unittest
{
    string yaml_input = "red:   '#ff0000'\ngreen: '#00ff00'\nblue:  '#0000ff'";

    auto colors = Loader(yaml_input).loadAll().front;
    assert(colors["red"] == "#ff0000");
    assert(colors["green"] == "#00ff00");
    assert(colors["blue"] == "#0000ff");
}

unittest {
    import std.conv : to;
    assert(Loader("42").loadAll().front.to!int == 42);
}
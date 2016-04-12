

//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.escapes;

private import std.array;
private import std.meta;
private import std.range;
private import std.typecons;
package:

///Translation table from YAML escapes to dchars.
// immutable dchar[dchar] fromEscapes;
///Translation table from dchars to YAML escapes.
immutable dchar[dchar] toEscapes;

alias escapeSeqs  = AliasSeq!(cast(dchar)'0',   cast(dchar)'a',     cast(dchar)'b',     cast(dchar)'t',     cast(dchar)'\t',    cast(dchar)'n',     cast(dchar)'v',     cast(dchar)'f',     cast(dchar)'r',     cast(dchar)'e', cast(dchar)' ',     cast(dchar)'\"', cast(dchar)'\\', cast(dchar)'N', cast(dchar)'_', cast(dchar)'L', cast(dchar)'P');

alias escapePairs = AliasSeq!(
    Tuple!(dchar,dchar)('\0', '0'),
    Tuple!(dchar,dchar)('\x07', 'a'),
    Tuple!(dchar,dchar)('\x08', 'b'),
    Tuple!(dchar,dchar)('\x09', 't'),
    Tuple!(dchar,dchar)('\x0A', 'n'),
    Tuple!(dchar,dchar)('\x0B', 'v'),
    Tuple!(dchar,dchar)('\x0C', 'f'),
    Tuple!(dchar,dchar)('\x0D', 'r'),
    Tuple!(dchar,dchar)('\x1B', 'e'),
    Tuple!(dchar,dchar)('"', '"'),
    Tuple!(dchar,dchar)('\\', '\\'),
    Tuple!(dchar,dchar)('\u0085', 'N'),
    Tuple!(dchar,dchar)('\xA0', '_'),
    Tuple!(dchar,dchar)('\u2028', 'L'),
    Tuple!(dchar,dchar)('\u2029', 'P'));

alias extraEscapes = AliasSeq!(
    Tuple!(dchar,dchar)('\x09', '\t'),
    Tuple!(dchar,dchar)(' ', ' '));

/// All YAML escapes.
alias escapeHexSeq = AliasSeq!('x', 'u', 'U');
/// YAML hex codes specifying the length of the hex number.

/// Covert a YAML escape to a dchar.
///
/// Need a function as associative arrays don't work with @nogc.
/// (And this may be even faster with a function.)
dchar fromEscape(dchar escape) @safe pure nothrow @nogc
{
    switch(escape)
    {
        foreach (tup; AliasSeq!(escapePairs, extraEscapes))
            case tup[1]: return tup[0];
        default:   assert(false, "No such YAML escape");
    }
}
/// Get the length of a hexadecimal number determined by its hex code.
///
/// Need a function as associative arrays don't work with @nogc.
/// (And this may be even faster with a function.)
uint escapeHexLength(dchar hexCode) @safe pure nothrow @nogc
{
    switch(hexCode)
    {
        case 'x': return 2;
        case 'u': return 4;
        case 'U': return 8;
        default:  assert(false, "No such YAML hex code");
    }
}


static this()
{
    toEscapes = assocArray(only(escapePairs));
}
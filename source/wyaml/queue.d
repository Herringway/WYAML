
//          Copyright Ferdinand Majerech 2011-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.queue;


/// Queue collection.
import core.stdc.stdlib;
import core.memory;

import std.container;
import std.range;
import std.traits;


package:

struct Queue(T) {
    DList!T list;
    ref T pop() {
        scope(success)
          list.removeFront();
        return peek();
    }
    ref T peek() {
        return list.front;
    }
    const(T) peek() const {
        return list.front;
    }
    void push(T val) {
        list.insertBack(val);
    }
    bool empty() {
        return list.empty;
    }
    size_t length() {
        return list.opSlice().walkLength();
    }
    size_t length() const {
        return ((cast()list).dup()).opSlice().walkLength();
    }
    int opApply(int delegate(ref T) nothrow dg) nothrow {
        int result;
        foreach (item; list.opSlice()) {
            result = dg(item);
            if (result)
                return result;
        }
        return result;
    }
}
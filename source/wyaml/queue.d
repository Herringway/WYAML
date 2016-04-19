//          Copyright Ferdinand Majerech 2011-2014.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module wyaml.queue;

import std.array;


package:

struct Queue(T) {
    T[] list;
    ref T pop() {
        scope(success)
          list.popFront();
        return list.front;
    }
    ref T peek() {
        return list.front;
    }
    const(T) peek() const {
        return list.front;
    }
    void push(T val) {
        list = list~val;
    }
    bool empty() {
        return list.empty;
    }
    size_t length() {
        return list.length;
    }
    size_t length() const {
        return list.length;
    }
    int opApply(int delegate(ref T) nothrow dg) nothrow {
        int result;
        foreach (item; list) {
            result = dg(item);
            if (result)
                return result;
        }
        return result;
    }
}
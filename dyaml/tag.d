
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

///YAML tag.
module dyaml.tag;

import dyaml.sharedobject;


///YAML tag (data type) struct. Encapsulates a tag to save memory and speed-up comparison.
struct Tag
{
    public:
        mixin SharedObject!(string, Tag);

        ///Construct a tag from a string representation.
        this(string tag)
        {
            if(tag is null || tag == "")
            {
                index_ = uint.max;
                return;
            }

            add(tag);
        }
}
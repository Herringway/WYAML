//          Copyright Ferdinand Majerech 2011.
//          Copyright Cameron Ross 2016.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

///Exceptions thrown by D:YAML and _exception related code.
module wyaml.exception;

import std.algorithm;
import std.array;
import std.conv;
import std.string;

/// Base class for all exceptions thrown by D:YAML.
class YAMLException : Exception {
	/// Construct a YAMLException with specified message and position where it was thrown.
	public this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow @nogc {
		super(msg, file, line);
	}
}

// Position in a YAML stream, used for error messages.
package struct Mark {
	/// Line number.
	package ushort line_;
	/// Column number.
	package ushort column_;

	/// Construct a Mark with specified line and column in the file.
	public this(const uint line, const uint column) @safe pure nothrow @nogc {
		line_ = cast(ushort) min(ushort.max, line);
		// This *will* overflow on extremely wide files but saves CPU time
		// (mark ctor takes ~5% of time)
		column_ = cast(ushort) column;
	}

	/// Get a string representation of the mark.
	public string toString() @safe pure nothrow const {
		// Line/column numbers start at zero internally, make them start at 1.
		static string clamped(ushort v) @safe pure nothrow {
			return (v + 1).text ~ (v == ushort.max ? " or higher" : "");
		}

		return "line " ~ clamped(line_) ~ ",column " ~ clamped(column_);
	}
}

// A struct storing parameters to the MarkedYAMLException constructor.
package struct MarkedYAMLExceptionData {
	// Context of the error.
	string context;
	// Position of the context in a YAML buffer.
	Mark contextMark;
	// The error itself.
	string problem;
	// Position of the error.
	Mark problemMark;
}

// Base class of YAML exceptions with marked positions of the problem.
package abstract class MarkedYAMLException : YAMLException {
	// Construct a MarkedYAMLException with specified context and problem.
	this(string context, const Mark contextMark, string problem, const Mark problemMark, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		const msg = context ~ '\n' ~ (contextMark != problemMark ? contextMark.toString() ~ '\n' : "") ~ problem ~ '\n' ~ problemMark.toString() ~ '\n';
		super(msg, file, line);
	}

	// Construct a MarkedYAMLException with specified problem.
	this(string problem, const Mark problemMark, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(problem ~ '\n' ~ problemMark.toString(), file, line);
	}

	// Construct a MarkedYAMLException with specified problem and both start and end markers.
	this(string problem, const Mark problemMarkStart, const Mark problemMarkEnd, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(problem ~ "\nStart:" ~ problemMarkStart.toString()~"\nEnd: "~problemMarkEnd.toString(), file, line);
	}

	/// Construct a MarkedYAMLException from a struct storing constructor parameters.
	this(ref const(MarkedYAMLExceptionData) data) @safe pure nothrow {
		this(data.context, data.contextMark, data.problem, data.problemMark);
	}
}

// Constructors of YAML exceptions are mostly the same, so we use a mixin.
//
// See_Also: YAMLException
package template ExceptionCtors() {
	public this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(msg, file, line);
	}
}

// Constructors of marked YAML exceptions are mostly the same, so we use a mixin.
//
// See_Also: MarkedYAMLException
package template MarkedExceptionCtors() {
	public this(string context, const Mark contextMark, string problem, const Mark problemMark, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(context, contextMark, problem, problemMark, file, line);
	}

	public this(string problem, const Mark problemMark, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(problem, problemMark, file, line);
	}
	public this(string problem, const Mark problemMarkStart, const Mark problemMarkEnd, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
		super(problem, problemMarkStart, problemMarkEnd, file, line);
	}

	public this(ref const(MarkedYAMLExceptionData) data) @safe pure nothrow {
		super(data);
	}
}

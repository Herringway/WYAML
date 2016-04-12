# WYAML
[![Build Status](https://travis-ci.org/Herringway/WYAML.svg?branch=master)](https://travis-ci.org/Herringway/WYAML)[![Coverage Status](https://coveralls.io/repos/github/Herringway/WYAML/badge.svg?branch=master)](https://coveralls.io/github/Herringway/WYAML?branch=master)

## Introduction

WYAML is an open-source range-based YAML parser and emitter. It is a fork of [D:YAML](https://github.com/kiith-sa/D-YAML). It is nearly YAML 1.1-compliant, with a few minor deviations from the spec.

## Features

- Easy to use, high level API and detailed debugging messages.
- Detailed API documentation and tutorials.
- Code examples.
- Supports all YAML 1.1 constructs. All examples from the YAML 1.1 specification are parsed correctly.
- Reads from and writes from/to character ranges.
- Supports any character type.
- Support for both block (Python-like, based on indentation) and flow (JSON-like, based on bracing) constructs.
- Support for YAML anchors and aliases.
- Support for default values in mappings.
- Support for custom tags (data types), and implicit tag resolution for custom scalar tags.
- All tags (data types) described at http://yaml.org/type/ are supported, with the exception of `tag:yaml.org,2002:yaml`, which is used to represent YAML code in YAML.
- Remembers YAML style information between loading and dumping if possible.
- Reuses input memory and uses slices to minimize memory allocations.
- There is no support for recursive data structures. There are no plans to implement this at the moment.


## Directory structure

| Directory   | Contents                       |
| ----------- | ------------------------------ |
| ./          | This README, utility scripts.  |
| ./docsrc    | Documentation sources.         |
| ./source    | Source code.                   |
| ./examples/ | Example projects using D:YAML. |
| ./test      | Unittest data.                 |


## Installing and tutorial

Documentation is available at https://herringway.github.io/wyaml.html

## License

D:YAML is released under the terms of the [Boost Software License 1.0](http://www.boost.org/LICENSE_1_0.txt). This license allows you to use the source code in your own projects, open source or proprietary, and to modify it to suit your needs. However, in source distributions, you have to preserve the license headers in the source code and the accompanying license file.

Full text of the license can be found in file [LICENSE_1_0.txt](LICENSE_1_0.txt).

## WYAML Credits

Written by Cameron "Herringway" Ross.

## D:YAML Credits

The original D:YAML was created by [Ferdinand Majerech aka Kiith-Sa](mailto:kiithsacmp[AT]gmail.com).

Parts of code based on [PyYAML](http://www.pyyaml.org) created by Kirill Simonov.

D:YAML was created using Vim and DMD on Debian, Ubuntu and Linux Mint as a YAML parsing
library for the [D programming language](http://www.dlang.org).

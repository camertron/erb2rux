## erb2rux

![Unit Tests](https://github.com/camertron/erb2rux/actions/workflows/unit_tests.yml/badge.svg?branch=master)

erb2rux is an ERB to [Rux](https://github.com/camertron/rux) converter. It's used to translate Rails view files, usually written in ERB (embedded Ruby) syntax, into Rux syntax. Rux allows you to write HTML in your Ruby code, much like JSX allows you to write HTML in your JavaScript. It's great for rendering [view components](https://viewcomponent.org/).

## Installation

Simply run `gem install erb2rux`.

## Usage

The project ships with a single executable called `erb2rux`. It takes any number of files as arguments, or a single "-" character to read from [standard input](https://en.wikipedia.org/wiki/Standard_streams). In the case of standard input, `erb2rux` will print the resulting Rux code to standard output (i.e. your terminal screen). Otherwise, the list of files will be transpiled and written to the same location as the original file, with either the default extension (.html.ruxt) or one you specify.

Here's an example showing how to transpile a single file:

```bash
erb2rux app/views/products/index.html.erb
```

This will create app/views/products/index.html.ruxt containing Rux code equivalent to the given ERB file.

To use a different extension, pass the -x option:

```bash
erb2rux -x .html.rux app/views/products/index.html.erb
```

Finally, here's the equivalent command using standard in/out:

```bash
cat app/views/products/index.html.erb | erb2rux -
```

## Running Tests

`bundle exec rspec` should do the trick.

## License

Licensed under the MIT license. See LICENSE for details.

## Authors

* Cameron C. Dutro: http://github.com/camertron

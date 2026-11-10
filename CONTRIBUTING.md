# Contributing to mb-sound

Since this library is meant to accompany a video series, most new features will
be targeted at what's covered in episodes as they are released.  If you think of
something cool to add that relates to the video series, then please open a pull
request.

Pull requests are also welcome if you want to add or improve support for new
platforms.

## Building and testing

Install the system packages and Ruby as in the README, then:

```bash
bundle install
bundle exec rake compile          # the C extensions (needed before anything runs)
bundle exec rspec                 # the test suite
bundle exec rake spec:parallel    # the same in parallel processes
bundle exec rspec --tag smoke     # every bin/ script with --help and a short render
```

`libasound2-dev` builds RtMidi's ALSA MIDI backend and `libjack-jackd2-dev`
its JACK one; `jackd2` runs the dummy JACK server some tests use, and
`graphviz` draws node graphs with `-g`.

The user guide's examples run as part of the suite
(`spec/lib/mb/sound/help/guide_spec.rb`), as do the console help's
(`spec/lib/mb/sound/help_spec.rb`): a change that breaks one shows up
there.

## How the library is organized

- `lib/` the library, `ext/` its C extensions, `bin/` scripts and demos,
  `spec/` the tests.
- `docs/guide/` the user guide, for musicians.
- `design/notes/` the design notes, one per part of the library (signal
  graph, filters, sequences, sessions, the console, ...), indexed by
  `design/notes/README.md`; `design/catalog.md` lists every node method
  and console help topic in one line each.
- `CLAUDE.md` holds the conventions coding agents follow in this
  repository (testing rules, gotchas).

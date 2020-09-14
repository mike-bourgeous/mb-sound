# mb-sound

A library of simple Ruby tools for processing sound.  This is a companion
library to an [educational video series I'm making about sound][0].

You'll find simple functions for loading and saving audio files, playing and
recording sound in realtime (on Linux, and only for really simple algorithms).

This is written in Ruby for speed of prototyping, convenience of the Ruby
command line, and for the sake of novelty.  Another reason is that, if we can
write sound algorithms that work fast enough in Ruby, then they'll definitely
be fast enough when ported to e.g. C, Rust, GLSL, etc.

More information may be added here as the video series progresses.  For now,
the most interesting things you'll want to know about using this library are
installing the dependencies, and launching the interactive command line.

## Installation and usage

You can either tinker within this project, or use it as a Git-sourced Gem in
your own projects.

If you don't already have a recent version of Ruby installed, and a Ruby version
manager of your choosing, I highly recommend using [RVM](https://rvm.io).  You
can find installation instructions for RVM at https://rvm.io.

### Using the project by itself

After getting RVM installed, you'll want to clone this repository, install
Ruby, and install the Gems needed by this code.

I also recommend making a separate projects directory just for this video
series.

This assumes basic familiarity with the Linux/macOS/WSL command line, or enough
independent knowledge to make this work on your operating system of choice.
I'll provide an overly detailed Linux example here:

```bash
# Make a project directory (substitute your own preferred paths)
cd ~/projects
mkdir sound_code_series
cd sound_code_series

# Install Ruby
# (disable-binary is needed on Ubuntu 20.04 to fix "/usr/bin/mkdir not found"
# error in the binary package of 2.7.1)
rvm install --disable-binary 2.7.1

# Clone the repo
git clone git@github.com:mike-bourgeous/mb-sound.git
cd mb-sound

# Install Gem dependencies
cd mb-sound
gem install bundler
bundle install
```

Now that everything's installed, you are ready to start playing with sound:

```bash
# Launch the interactive command line
bin/pry.rb
```

See the Examples section for some things to try.


### Using the project as a dependency

If you're already familiar with Ruby and Gems, then you can add this repo as a
dependency to a new project's Gemfile.

*TODO: add gemspec so this actually works*

```ruby
# your-project/Gemfile
gem 'mb-sound', git: 'git@github.com:mike-bourgeous/mb-sound.git'
```

## Examples

TODO: Examples will be added as the library progresses.

## Testing

You can run the integrated test suite with `rspec`.

## Contributing

Since this library is meant to accompany a video series, most new features will
be targeted at what's covered in episodes as they are released.  If you think of
something cool to add that relates to the video series, then please open a pull
request.

Pull requests are also welcome if you want to add or improve support for new
platforms.

## License

This project is released under a 2-clause BSD license.  See the LICENSE file.

Note, however, that if you use the FFT routines from FFTW, your app may be
subject to the GPL.

## Standing on the shoulders of giants

### Dependencies
This code uses some really cool other projects either directly or indirectly:

- FFMPEG
- Numo gems
- Pry interactive console for Ruby
- sndfile

### References

There are lots of excellent resources out there for learning sound and signal
processing:

- I've created a [playlist with some cool videos by others][1]
- [Circles, sines, and signals][2] is a great interactive demonstration of
  waves and Fourier transforms
- Online [books by Julius O. Smith][3] (I recommend buying the print versions)


[0]: https://www.youtube.com/playlist?list=PLpRqC8LaADXnwve3e8gI239eDNRO3Nhya
[1]: https://www.youtube.com/playlist?list=PLpRqC8LaADXlYhKRTwSpdW3ineaQnM9zK
[2]: https://jackschaedler.github.io/circles-sines-signals/

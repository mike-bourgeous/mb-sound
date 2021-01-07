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

There are some base packages you'll need first:

```bash
# Debian-/Ubuntu-based Linux (macOS/Arch/CentOS will differ)
sudo apt-get install ffmpeg gnuplot-qt
```

Then you'll want to install Ruby 2.7.2.

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
# error in the binary package of 2.7.2)
rvm install --disable-binary 2.7.2

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
bin/sound.rb
```

See the Examples section for some things to try.


### Using the project as a dependency

If you're already familiar with Ruby and Gems, then you can add this repo as a
dependency to a new project's Gemfile.

```ruby
# your-project/Gemfile
gem 'mb-sound', git: 'https://github.com/mike-bourgeous/mb-sound.git'

# Until https://github.com/yoshoku/numo-pocketfft/pull/4 is merged, this fixes
# occasional crashing in FFT code
gem 'numo-pocketfft', git: 'https://github.com/mike-bourgeous/numo-pocketfft.git', branch: 'fix-issue-3-crash-temporary-branch'
```

## Examples

These examples can be run in the `bin/sound.rb` interactive environment.  There
are other examples in the scripts under the `bin/` directory.

### Generating tones

```ruby
5.times do
  play 100.hz.triangle.at(-20.db).for(0.25)
  play 133.hz.triangle.at(-20.db).for(0.25)
  play 150.hz.triangle.at(-20.db).for(0.25)
  play 100.hz.triangle.at(-20.db).for(0.25)
  play 200.hz.ramp.at(-23.db).for(1.6)
end
```

You can play different tones in each channel:

```ruby
# Stereo octave
play [200.hz, 100.hz]

# Binaural beat
play [100.hz, 103.hz]
```

### Calculating wavelength and frequency

There are DSL methods for working with distances and wavelengths:

```ruby
1.hz.wavelength
# => 343 meters

343.meters.hz
# => #<MB::Sound::Tone:0x000055f66a23a2b0
# @amplitude=0.1,
# @duration=5.0,
# @frequency=1.0,
# @oscillator=nil,
# @rate=48000,
# @wave_type=:sine,
# @wavelength=343.0 meters>
```

You can convert between feet and meters:

```ruby
1000.hz.wavelength.feet
# => 1.1253280839895015 feet

1.foot.meters
# => 0.30479999999999996 meters
```

### Filtering sounds

Filters delay and/or change the volume of different frequencies.

```ruby
tone = 432.hz.ramp
filtered = filter(tone, frequency: 1500, quality: 0.25)

# Compare the unfiltered and filtered tones
plot [tone, filtered[0]], samples: 48000*3/432.0

play filtered
```

```
      +---------------------------------------------------------------------------------+
 0.08 |-+      ***+*         +           +****       +           +  ****    +         +-|
 0.06 |-+    ***   *                   ***   *                   ***   *      0 *******-|
 0.04 |-+  ***     *                 ***     *                 ***     *              +-|
 0.02 |-***        *              ****       *               ***       *              +-|
    0 |**          *            ***          *            ***          *              +-|
      |            *          ***            *          ***            *          ***   |
-0.02 |-+          *       ***               *       ****              *        ***   +-|
-0.04 |-+          *     ***                 *     ***                 *     ***      +-|
-0.06 |-+          *   ***                   *   ***                   *   ***        +-|
-0.08 |-+         +****      +           +   ****    +           +     * ***+         +-|
      +---------------------------------------------------------------------------------+
      0           50        100         150         200         250        300         350

      +---------------------------------------------------------------------------------+
 0.08 |-+         +          +           +           +           +          +         +-|
 0.06 |-+         **                        **                        **      1 *******-|
      |         *** *                     *** *                     *** *               |
 0.04 |-+    ***    **                  ***   **                  ***   **            +-|
 0.02 |-+ ****       *               ****      *                ***      *            +-|
    0 |****          **            ***         **            ***         **           +-|
-0.02 |-+             ***       ****            ***       ****            ***         +-|
-0.04 |-+               *********                 *********                 ********* +-|
      |                                                                                 |
-0.06 |-+                                                                             +-|
-0.08 |-+         +          +           +           +           +          +         +-|
      +---------------------------------------------------------------------------------+
      0           50        100         150         200         250        300         350
```

### Playing a sound file

```ruby
play 'sounds/sine/sine_100_1s_mono.flac', gain: -6.db
```

### Loading a sound file into memory

```ruby
data = read 'sounds/sine/sine_100_1s_mono.flac'
# => [Numo::DFloat#shape=[48000]
# [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.19209e-07, ...]]
play data, rate: 48000
```

### Plotting sounds

```ruby
plot 100.hz.ramp
```

```
       +-------------------------------------------------------------------+
  0.08 |-+    +     ****   +      +      +      +   *****    +      +    +-|
       |         ****  *                          ***   *        0 ******* |
  0.06 |-+     ***     *                        ***     *                +-|
  0.04 |-+   ***       *                     ****       *                +-|
       |  ****         *                   ***          *                  |
  0.02 |***            *                 ***            *                +-|
     0 |*+             *              ****              *              **+-|
 -0.02 |-+             *            ***                 *            *** +-|
       |               *          ***                   *         ****     |
 -0.04 |-+             *       ****                     *       ***      +-|
 -0.06 |-+             *     ***                        *     ***        +-|
       |               *   ***                          *  ****            |
 -0.08 |-+    +      + * ***      +      +      +      +**** +      +    +-|
  -0.1 +-------------------------------------------------------------------+
       0     100    200   300    400    500    600    700   800    900    1000
```

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

## Standing on the shoulders of giants

### Dependencies

This code uses some really cool other projects either directly or indirectly:

- FFMPEG
- Numo::NArray
- Numo::Pocketfft
- Pry interactive console for Ruby
- GNUplot
- The MIDI Nibbler gem

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
[3]: https://ccrma.stanford.edu/~jos/#books

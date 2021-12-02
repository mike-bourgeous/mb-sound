# mb-sound

[![Tests](https://github.com/mike-bourgeous/mb-sound/actions/workflows/test.yml/badge.svg)](https://github.com/mike-bourgeous/mb-sound/actions/workflows/test.yml)

A library of simple Ruby tools for processing sound.  This is a companion
library to an [educational video series I'm making about sound][0].

You'll find simple functions for loading and saving audio files, playing and
recording sound in realtime (on Linux, and only for really simple algorithms),
and plotting sounds.

https://user-images.githubusercontent.com/5015814/115160392-c485e500-a04c-11eb-8b5f-675f3c3eef8c.mp4

This is written in Ruby for speed of prototyping, convenience of the Ruby
command line, and for the sake of novelty.  Another reason is that, if we can
write sound algorithms that work fast enough in Ruby, then they'll definitely
be fast enough when ported to e.g. C, Rust, GLSL, etc.

More information may be added here as the video series progresses.  For now,
the most interesting things you'll want to know about using this library are
installing the dependencies, and launching the interactive command line.

You might also be interested in [mb-math][4], [mb-geometry][5], and
[mb-util][6].

## Quick start

Clone the repo, follow the [installation instructions
below](#installation-and-usage), then run `bin/sound.rb`.

Try this:

```ruby
play file_input('sounds/synth0.flac') * 120.hz.fm(360.hz.at(1000))
```

## Examples

These examples can be run in the `bin/sound.rb` interactive environment.  There
are other examples in the scripts under the `bin/` directory, such as an FM
synthesizer in `bin/fm_synth.rb`.

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

# Surround sound chord
play [100.hz, 200.hz, 300.hz, 400.hz, 500.hz, 600.hz, 250.hz, 333.hz].map(&:triangle)
```

#### Simple AM tones

```ruby
play 123.hz * 369.hz
```

#### Simple FM tones

Frequency modulation is also possible:

```ruby
play 123.hz.fm(369.hz.at(1000))
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
filtered = 432.hz.ramp.filter(1500.hz.lowpass(quality: 0.25))

# Compare the unfiltered and filtered tones
plot [tone, filtered], samples: 48000*3/432.0

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

You can also plot the spectrum of a playing sound instead of its waveform:

```ruby
play 'sounds/sine/log_sweep_20_20k.flac', spectrum: true
```

You can filter the sound as well:

```ruby
play file_input('sounds/synth0.flac').filter(1500.hz.lowpass(quality: 8))
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

```ruby
spectrum 100.hz.ramp
# or
plot 100.hz.ramp, spectrum: true
```

```
     +---------------------------------------------------------------------+
     |      **                 +                         +                 |
 -30 |-+    * *      *   *                                       0 *******-|
     |     *  *      *   *   * *                                           |
 -40 |-+   *  *     **   *   * * * *                                     +-|
     |    *   *     * *  **  * * * ** ****                                 |
     |    *    *    * * * * ** * * ** **********                           |
 -50 |-+ *     *   *  * * * ** * * ** ***************                    +-|
     |  *      *   *  * * * ** * * ** ********************                 |
 -60 |-+*       *  *  * * * * * ***** **************************         +-|
     | *        * *   * * * * * * * *** *******************************    |
     | *        * *    **  ** * * * *** ***********************************|
 -70 |*+        * *    *   *  * * * *** ***********************************|
     |*          *     *   *  *+* * *** ***********************************|
 -80 +---------------------------------------------------------------------+
     1                         10                       100
```

### Visualizing realtime sound

```ruby
loopback(plot: { spectrum: true })
```

### Working with MIDI

Look under the `lib/mb/sound/midi/` directory, or refer to the example scripts
below.

#### `bin/midi_info.rb`

This script displays information about a MIDI file, including the song title,
track names, and number of events on each track.  Uses the midilib gem for
parsing MIDI files.

```bash
bin/midi_info.rb spec/test_data/midi.mid
```

```
midi.mid: Unnamed
-----------------

 # |  Name   | Inst. | Ch. mask | Event ch. | Events | Notes
---+---------+-------+----------+-----------+--------+-------
 0 | Unnamed |       | []       | []        | 3      | 0
 1 | Unnamed |       | [0]      | [0]       | 32     | 26
```

#### `bin/midi_cc_chart.rb`

This displays a table with MIDI Control Change (CC) values, either from a MIDI
input or a MIDI file, in real time.

```bash
bin/midi_cc_chart.rb spec/test_data/midi.mid
```

```
 CCs |  0  |  1  |  2  |  3  |  4  |  5  |  6  |  7  |  8  |  9
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 0   | 16  |     |     |     |     |     | 12  |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 10  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 20  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 30  |     |     | 0   |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 40  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 50  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 60  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 70  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 80  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 90  |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 100 |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 110 |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 120 |     |     |     |     |     |     |     |     |     |
```

#### `bin/midi_note_chart.rb`

This displays the attack and release velocities of MIDI Note On and Note Off
events in a grid, either from a MIDI input or a MIDI file, in real time.

```bash
bin/midi_note_chart.rb spec/test_data/midi.mid
```

```
 ### |  C  | C#  |  D  | D#  |  E  |  F  | F#  |  G  | G#  |  A  | A#  |  B
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
-1   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 0   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 1   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 2   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 3   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 4   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 5   | 0   | 118 |     | 0   |     | 33  |     | 0   | 31  |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 6   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 7   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 8   |     |     |     |     |     |     |     |     |     |     |     |
-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----
 9   |     |     |     |     |     |     |     |     |     |     |     |
```

#### `bin/ep2_syn.rb`

This is the synthesizer I wrote for [episode 2][7] of my [Code, Sound &
Surround video series][0].

```bash
bin/ep2_syn.rb
```

## Installation and usage

You can either tinker within this project, or use it as a Git-sourced Gem in
your own projects.

There are some base packages you'll need first:

```bash
# Debian-/Ubuntu-based Linux (macOS/Arch/CentOS will differ)
sudo apt-get install ffmpeg gnuplot-qt

# macOS (with Homebrew)
brew install ffmpeg gnuplot
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

# Also specify Git location for other mb-* dependencies
gem 'mb-util', git: 'https://github.com/mike-bourgeous/mb-util.git'
gem 'mb-math', git: 'https://github.com/mike-bourgeous/mb-math.git'
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

## See also

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
[4]: https://github.com/mike-bourgeous/mb-math
[5]: https://github.com/mike-bourgeous/mb-geometry
[6]: https://github.com/mike-bourgeous/mb-util
[7]: https://www.youtube.com/watch?v=aS43s6TWnIY

require 'cmath'
require 'numo/narray'

require_relative 'sound/version'

module MB
  # Convenience functions for making quick work of sound.
  #
  # Top-level namespace for the mb-sound library.
  module Sound
    class FileExistsError < IOError; end

    # Make sure that plotters are resized when the terminal window changes
    # size.
    trap :WINCH do
      Thread.new do
        old_pt = @pt
        old_pg = @pg
        @pt&.close
        @pg&.close
        @pt = nil
        @pg = nil

        plotter(graphical: false) if old_pt
        plotter(graphical: true) if old_pt
      end
    end

    # Returns the current time from the system's monotonically increasing
    # clock.  A shorthand for Process.clock_gettime(Process::CLOCK_MONOTONIC).
    def self.clock_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Reads an entire sound file into an array of Numo::NArrays, one per
    # channel.  Always resamples to 48kHz.
    #
    # See MB::Sound::FFMPEGInput for more flexible sound input.
    def self.read(filename, max_frames: nil)
      input = MB::Sound::FFMPEGInput.new(filename, resample: 48000)
      input.read(max_frames || input.frames)
    ensure
      input&.close
    end

    # Writes an Array of Numo::NArrays into the given sound file.  If the sound
    # file already exists and +:overwrite+ is false, an error will be raised.
    #
    # See MB::Sound::FFMPEGOutput for more flexible sound output.
    def self.write(filename, data, rate:, overwrite: false)
      if !overwrite && File.exist?(filename)
        raise FileExistsError, "#{filename.inspect} already exists"
      end

      data = make_array_plottable(data)

      output = MB::Sound::FFMPEGOutput.new(filename, rate: rate, channels: data.length)
      output.write(data)
    ensure
      output&.close
    end

    # Lists all files under the given directory, or under a 'sounds' directory
    # if no path is given.
    def self.list(dir=nil)
      path = dir || File.join(Dir.pwd, 'sounds')
      files = Dir[File.join(path, '**', '*.*')].map { |f|
        File.relative_path(dir || Dir.pwd, f)
      }
      puts files
    end

    # Plays a sound file if a String is given, a generated tone if a Tone is
    # given, or an audio buffer if an audio buffer is given.  If an audio
    # buffer or tone is given, the sample rate should be specified (defaults to
    # 48k).  The sample rate is ignored for an audio filename.
    def self.play(file_tone_data, rate: 48000, gain: 1.0, plot: nil, graphical: false, device: nil)
      header = "\e[H\e[J\e[36mPlaying\e[0m #{MB::Sound::U.highlight(file_tone_data)}"
      puts header

      plot = { header_lines: header.lines.count, graphical: graphical } if plot.nil? || plot == true

      case file_tone_data
      when String
        return play_file(file_tone_data, gain: gain, plot: plot, device: device)

      when Array, Numo::NArray
        data = make_array_plottable(file_tone_data)
        data = data * 2 if data.length < 2
        channels = data.length

        # TODO: if this code needs to be modified much in the future, come up
        # with a shared way of chunking data that can work for all play and
        # plot methods
        output = MB::Sound.output(rate: rate, channels: channels, plot: plot, device: device)
        (0...data[0].length).step(960).each do |offset|
          output.write(data.map { |c| c[offset...([offset + 960, c.length].min)] })
        end

      when Tone
        output = MB::Sound.output(rate: rate, plot: plot, device: device)
        file_tone_data.write(output)

      else
        raise "Unsupported type #{file_tone_data.class.name} for playback"
      end
    ensure
      output&.close
    end

    # Plays the given filename using the default audio output returned by
    # MB::Sound.output.  The +:channels+ parameter may be used to force mono
    # playback (mono sound is converted to stereo by default), or to ask ffmpeg
    # to upmix or downmix audio to a different number of channels.
    def self.play_file(filename, channels: nil, gain: 1.0, plot: true, device: nil)
      input = MB::Sound::FFMPEGInput.new(filename, channels: channels, resample: 48000)
      output = MB::Sound.output(channels: channels || (input.channels < 2 ? 2 : input.channels), plot: plot, device: device)

      # TODO: Move all playback loops to a processing helper method when those are added
      loop do
        data = input.read(960)
        break if data.nil? || data.empty? || data[0].empty?

        data.map { |d|
          d.inplace * gain
        }

        # Ensure the output is at least stereo (Pulseaudio plays nothing for
        # mono output on my system)
        data = data * 2 if data.length == 1 && channels.nil?

        output.write(data)
      end

    ensure
      input&.close
      output&.close
    end

    # Tries to auto-detect an input device for recording sound.  Returns a
    # sound input stream with a :read method.
    #
    # For input types that support naming a specific device, the INPUT_DEVICE
    # environment variable, the DEVICE environment variable, or the +:device+
    # parameter may be used to override the default.  Environment variables
    # take precedence.  For Jackd, the device is a prefix for port names, with
    # the default being 'system:capture_'.
    #
    # See FFMPEGInput, JackInput, and AlsaInput for more flexible recording.
    def self.input(rate: 48000, channels: 2, device: nil, buffer_size: nil)
      case RUBY_PLATFORM
      when /linux/
        if device
          MB::Sound::AlsaInput.new(device: device, rate: rate, channels: channels, buffer_size: buffer_size)
        elsif `pgrep jackd`.strip.length > 0
          o = MB::Sound::JackInput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)
        elsif `pgrep pulseaudio`.strip.length > 0
          MB::Sound::AlsaInput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
        else
          MB::Sound::AlsaInput.new(device: 'default', rate: rate, channels: channels, buffer_size: buffer_size)
        end

      else
        raise NotImplementedError, 'TODO: support other platforms'
      end
    end

    # Tries to auto-detect an output device for playing sound.  Returns a sound
    # output stream with a :write method.
    #
    # For output types that support naming a specific device, the OUTPUT_DEVICE
    # environment variable, the DEVICE environment variable or +:device+
    # parameter may be used to override the default.  Environment variables
    # take precedence.  For JackD, the device is a prefix for port names, with
    # the default being 'system:playback_'.
    #
    # See FFMPEGOutput, JackOutput, and AlsaOutput for more flexible playback.
    #
    # Pass either true or a Hash of options for MB::Sound::PlotOutput in
    # +:plot+ to enable live plotting.
    def self.output(rate: 48000, channels: 2, device: nil, buffer_size: nil, plot: nil)
      o = nil
      case RUBY_PLATFORM
      when /linux/
        if `pgrep jackd`.strip.length > 0
          o = MB::Sound::JackOutput.new(ports: { device: device, count: channels }, buffer_size: buffer_size)
        elsif `pgrep pulseaudio`.strip.length > 0
          o = MB::Sound::AlsaOutput.new(device: 'pulse', rate: rate, channels: channels, buffer_size: buffer_size)
        else
          o = MB::Sound::AlsaOutput.new(device: device || 'default', rate: rate, channels: channels, buffer_size: buffer_size)
        end

      else
        raise NotImplementedError, 'TODO: support other platforms'
      end

      if plot
        graphical = plot.is_a?(Hash) && plot[:graphical] || false
        p = { plot: plotter(graphical: graphical) }
        p.merge!(plot) if plot.is_a?(Hash)

        o = MB::Sound::PlotOutput.new(o, **p)
      end

      o
    end

    # Endlessly streams audio in non-overlapping +:block_size+ chunks from
    # MB::Sound.input to MB::Sound.output.
    #
    # If a block is given, the audio read will be yielded to the block as an
    # Array of Numo::NArrays.
    #
    # Press Ctrl-C to interrupt, or call break in the block.
    def self.loopback(rate: 48000, channels: 2, block_size: 512, plot: true)
      puts "\e[H\e[J"

      inp = input(rate: rate, channels: channels, buffer_size: block_size)
      inp.read(1)
      outp = output(rate: rate, channels: channels, buffer_size: block_size, plot: plot)
      loop do
        data = inp.read(block_size)
        data = yield data if block_given?
        outp.write(data)
      end
    ensure
      inp&.close
      outp&.close
    end

    # Returns either a terminal-based plotting object if +graphical+ is false,
    # or a graphical window-based plotting object if +graphical+ is true.
    def self.plotter(graphical:)
      @pt ||= MB::Sound::Plot.terminal(height_fraction: 0.8)
      @pg ||= MB::Sound::Plot.new if graphical
      graphical ? @pg : @pt
    end

    # If given a raw NArray or an array of numeric values, wraps it in an
    # Array.  If given a Tone or array of Tones, calls its/their
    # MB::Sound::Tone#generate method.
    def self.make_array_plottable(array)
      case array
      when Numo::NArray
        [array]

      when Array
        case array[0]
        when Numeric
          [array]

        else
          array.map { |el|
            el = el.generate if el.is_a?(MB::Sound::Tone)
            el
          }
        end

      when MB::Sound::Tone
        [array.generate]

      else
        array
      end
    end

    # Plots a subset of the given audio file, test tone, or data, starting at
    # +offset+, and plotting the following +samples+ samples.  If +all+ is true
    # then the entirety of the file, tone, or data will be plotted in slices of
    # +samples+ samples.
    def self.plot(file_tone_data, samples: 960, offset: 0, all: false, graphical: false)
      # FIXME: This function is hard to read
      STDOUT.write("\e[H\e[2J") if all == true

      if all == true || all == false
        header = "\e[36mPlotting #{MB::Sound::U.highlight(file_tone_data)}\e[0m"
        header_lines = header.lines.count
        puts header
      end

      case file_tone_data
      when Array, Numo::NArray
        data = make_array_plottable(file_tone_data)

      when String
        # TODO: Read speaker names
        data = read(file_tone_data, max_frames: all ? nil : samples + offset)

      when Tone
        data = [file_tone_data.generate(all ? nil : samples + offset)]

      else
        raise "Cannot plot type #{file_tone_data.class.name}"
      end

      p = plotter(graphical: graphical)

      if all == true
        t = clock_now

        until offset >= data[0].length
          STDOUT.write("\e[#{header_lines}H\e[36mPress Ctrl-C to stop  \e[1;35m#{offset} / #{data[0].length}\e[0m\e[K\n")

          p.yrange(data.map(&:min).min, data.map(&:max).max) if p.respond_to?(:yrange)

          plot(data, samples: samples, offset: offset, all: nil, graphical: graphical)

          now = clock_now
          elapsed = [now - t, 0.1].min
          t = now

          offset += elapsed * 48000

          STDOUT.flush
          sleep 0.02
        end
      else
        data = data.map { |c| c[offset...([offset + samples, c.length].min)] || [] }

        p.yrange(data.map(&:min).min, data.map(&:max).max) if p.respond_to?(:yrange) && !all.nil?

        @lines = p.plot(data.map.with_index { |c, idx| [idx.to_s, c] }.to_h, print: false)
        puts @lines
      end

      nil
    ensure
      if all == true
        if graphical
          @pg.close
          @pg = nil
        elsif @pt.respond_to?(:height)
          puts "\e[#{@pt.height + (header_lines || 2) + 2}H"
        end
      end
    end

    # Silly experiment for retrieving notes by name as ruby constants.
    def self.const_missing(name)
      MB::Sound::Note.new(name)
    rescue ArgumentError
      super(name)
    end
  end
end

require_relative 'sound/u'
require_relative 'sound/m'
require_relative 'sound/io_input'
require_relative 'sound/io_output'
require_relative 'sound/ffmpeg_input'
require_relative 'sound/ffmpeg_output'
require_relative 'sound/alsa_input'
require_relative 'sound/alsa_output'
require_relative 'sound/jack_input'
require_relative 'sound/jack_output'
require_relative 'sound/oscillator'
require_relative 'sound/tone'
require_relative 'sound/note'
require_relative 'sound/plot'
require_relative 'sound/plot_output'

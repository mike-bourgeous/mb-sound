module MB
  module Sound
    # Command-line interface methods for playing sounds.  MB::Sound extends
    # itself with this module.
    module PlaybackMethods
      # Plays a sound file if a String is given, a generated tone if a Tone is
      # given, or an audio buffer if an audio buffer is given.  If an audio
      # buffer or tone is given, the sample rate should be specified (defaults to
      # 48k).  The sample rate is ignored for an audio filename.
      #
      # If +spectrum+ is true, then each chunk of audio plotted is shown in the
      # frequency domain instead of the time domain.
      #
      # If the PLOT environment variable is set to '0', then plotting defaults
      # to false.  Otherwise, plotting defaults to true.
      #
      # +:clear+ - Whether to clear the screen before beginning playback.
      # +:shared_output+ - If false (and no +:output+ is given), plays to a new
      #                    output that is closed when playback ends, instead
      #                    of the cached default output.  See #bg.
      def play(file_tone_data, output: nil, sample_rate: 48000, gain: 1.0, plot: nil, graphical: false, spectrum: false, device: nil, clear: true, quiet: false, shared_output: true)
        # Outputs created here for unshared playback, closed by the ensure
        # block below (also when a background player is killed)
        owned_outputs = []
        new_output = ->(**kwargs) {
          MB::Sound.output(**kwargs, shared: shared_output).tap { |o| owned_outputs << o unless shared_output }
        }

        clear_esc = clear ? "\e[H\e[J" : ''
        header = MB::U.wrap("#{clear_esc}\e[36mPlaying\e[0m #{playback_info(file_tone_data)}".lines.map(&:strip).join(' ') + "\n\n")
        $stderr.puts header unless quiet

        plot = false if quiet && plot.nil?
        plot = false if ENV['PLOT'] == '0' && plot.nil?
        plot = { header_lines: header.lines.count, graphical: graphical } if plot.nil? || plot == true
        plot[:spectrum] = spectrum if plot.is_a?(Hash) && !plot.include?(:spectrum)

        if file_tone_data.is_a?(Numo::NArray) || (file_tone_data.is_a?(MB::Sound::GraphNode) && !file_tone_data.respond_to?(:read))
          file_tone_data = [file_tone_data]
        end

        case file_tone_data
        when String
          return play_file(file_tone_data, gain: gain, plot: plot, device: device, output: output, new_output: new_output)

        when IOInput, InputBufferWrapper
          return play_input(file_tone_data, gain: gain, plot: plot, device: device, output: output, new_output: new_output)

        when Array
          if !file_tone_data.empty? && file_tone_data.all?(GraphNode)
            bufsize = file_tone_data.map(&:graph_buffer_size).compact.min # nil is ok here

            output ||= new_output.call(
              sample_rate: sample_rate,
              channels: MB::M.max(2, file_tone_data.length),
              plot: plot,
              device: device,
              buffer_size: bufsize
            )

            nodes = file_tone_data.map { |d|
              if d.sample_rate != sample_rate
                d.resample(sample_rate)
              else
                d
              end
            }

            input = nodes.as_input(output.channels)

            loop do
              buf = input.read(output.buffer_size)
              break if buf.nil? || buf.empty? || buf.any? { |d| d.nil? || d.empty? }

              output.write(buf)
            end

          else
            data = any_sound_to_array(file_tone_data)
            data = data * 2 if data.length < 2
            channels = data.length

            output ||= new_output.call(sample_rate: sample_rate, channels: channels, plot: plot, device: device)
            buffer_size = output.buffer_size

            # TODO: if this code needs to be modified much in the future, come up
            # with a shared way of chunking data that can work for all play,
            # write, and plot methods.  Maybe convert everything to signal nodes?
            #
            # TODO: maybe use ArrayInput
            (0...data[0].length).step(buffer_size).each do |offset|
              output.write(data.map { |c|
                MB::M.zpad(c[offset...([offset + buffer_size, c.length].min)], buffer_size)
              })
            end
          end

        else
          raise "Unsupported type #{file_tone_data.class.name} for playback"

        end

        $stderr.puts "\n\n" unless quiet

      ensure
        owned_outputs&.each(&:close)
      end

      # The longest #render will run when no length is given and the sounds
      # never end.
      MAX_RENDER_SECONDS = 600

      # Plays a sound in the background and returns its player name for
      # #stop.  The prompt stays available, so you can keep working while it
      # plays (e.g. change #bpm or start more sounds).
      #
      # Give a Symbol +name+ first to play in a named slot.  Running #bg again
      # with the same name replaces the old sound in sync when the new one
      # starts, so you can edit a line and re-run it to iterate.  Without a
      # name, the sound gets the lowest unused number.
      #
      # +:fade+ fades the sound in over that many seconds, and crossfades
      # from a sound it replaces.
      #
      # Accepts a GraphNode, an Array of GraphNodes (one per channel), or a
      # sound filename.  Everything played with #bg is mixed in one shared
      # Session, locked to one timeline, so sequences stay in sync.  If
      # something is already playing, the new sound starts on the next bar;
      # pass +:at+ to change that (:now, :beat, :bar, :clip, or a note length
      # grid; see Session#add).
      #
      # Errors during playback are printed and remove only the sound that
      # failed.
      #
      # Example (bin/sound.rb):
      #     bass = seq(C2, C2, rest, C3, C2, rest, As1, G1).n16.loop
      #     bg :bass, bass.tone.ramp.at(1).filter(:lowpass, cutoff: 250 + bass.env(0.001, 0.012, 0, 0.012) * 4000, quality: 4).softclip(0.1, 0.5)
      #     bg bass.transpose(12).tone.triangle.at(0.3) * bass.env    # player 1, joins on the next bar
      #     bpm 140
      #     stop       # stops the last one started (player 1)
      #     hush fade: 4    # fades everything out over 4 seconds
      def bg(name_or_sound, sound = nil, at: nil, fade: nil)
        name, sound = sound.nil? ? [nil, name_or_sound] : [name_or_sound, sound]
        raise ArgumentError, ':all is reserved for stop(:all)' if name == :all

        Session.default.add(sound, at: at, name: name, fade: fade)
      end

      # Stops background players (see #bg): with no arguments, the most
      # recently started one; with names or numbers, those players; with
      # :all, every player (see also #hush).  With +:fade+, players fade out
      # over that many seconds instead of stopping abruptly.  Returns the
      # names of the players that were stopped.  When nothing is left
      # playing, the timeline pauses where it is (see SequenceMethods#seek and
      # #rewind).
      def stop(*names, fade: nil)
        session = Session.default
        return [session.remove_last(fade: fade)].compact if names.empty?
        return session.remove(fade: fade) if names == [:all]

        stopped = session.remove(*names, fade: fade)
        (names - stopped).each do |name|
          warn "No background player #{name.inspect} is playing"
        end
        stopped
      end

      # Stops every background player, fading out over +:fade+ seconds if
      # given.  See #stop.
      def hush(fade: nil)
        stop(:all, fade: fade)
      end

      # Returns a Hash from background player name (see #bg) to a
      # description of what it is playing.
      def players
        Session.default.players
      end

      # Renders +sounds+ (GraphNodes, Arrays of GraphNodes, or filenames) to
      # an audio file as fast as possible.  All sounds start together at the
      # beginning of a fresh timeline, at the current tempo unless +:bpm+ is
      # given.  Rendering stops after +:bars+ or +:seconds+, or when every
      # sound has ended.  Returns the number of seconds rendered.
      #
      # Build fresh graphs to render, rather than rendering graphs that are
      # playing in the background, because graphs keep their playback state.
      #
      # Example (bin/sound.rb):
      #     bass = seq(C2, C2, rest, C3).n16.loop
      #     render '/tmp/bass.flac', bass.tone.ramp.at(1) * bass.env * 0.5, bars: 4
      def render(filename, *sounds, bars: nil, seconds: nil, bpm: nil, channels: 2, overwrite: false, buffer_size: 800)
        raise ArgumentError, 'Pass one or more sounds to render' if sounds.empty?
        raise ArgumentError, 'Pass bars: or seconds:, not both' if bars && seconds

        transport = Sequence::Transport.new(bpm: bpm || Sequence.transport.bpm, bar_length: Sequence.transport.bar_length)
        output = file_output(filename, channels: channels, overwrite: overwrite)
        session = Session.new(output: output, transport: transport, channels: channels, buffer_size: buffer_size, realtime: false, raise_errors: true)

        rate = output.sample_rate
        seconds = transport.seconds(bars.to_r * transport.bar_length) if bars
        limit = ((seconds || MAX_RENDER_SECONDS) * rate).round

        sounds.each { |s| session.add(s, at: :now) }

        frames = 0
        until frames >= limit || session.idle?
          count = MB::M.min(buffer_size, limit - frames)
          session.process_buffer(count)
          frames += count
        end

        if seconds.nil? && !session.idle?
          warn "Stopped rendering #{filename} after #{MAX_RENDER_SECONDS} seconds; pass bars: or seconds: for sounds that never end"
        end

        frames.to_f / rate

      ensure
        session&.close
      end

      private

      # Plays the given filename using the default audio output returned by
      # MB::Sound.output.  The +:channels+ parameter may be used to force mono
      # playback (mono sound is converted to stereo by default), or to ask ffmpeg
      # to upmix or downmix audio to a different number of channels.
      def play_file(filename, channels: nil, gain: 1.0, plot: true, device: nil, output:, new_output: MB::Sound.method(:output))
        input = MB::Sound::FFMPEGInput.new(filename, channels: channels, resample: 48000)
        play_input(input, gain: gain, plot: plot, device: device, output: output, new_output: new_output)
      end

      # Plays the given audio input object (e.g. MB::Sound::FFMPEGInput) to
      # either a given output, or the system default output (or another output
      # from the +:new_output+ callable; see #play).
      def play_input(input, channels: nil, gain:, plot:, device:, output:, new_output: MB::Sound.method(:output))
        output ||= new_output.call(channels: channels || (input.channels < 2 ? 2 : input.channels), plot: plot, device: device)

        buffer_size = output.buffer_size

        # TODO: Move all playback loops to a processing helper method when those are added
        loop do
          data = input.read(buffer_size)
          break if data.nil? || data.empty? || data[0].empty?

          # Apply gain and pad the final input chunk to the output buffer size
          data = data.map { |d|
            MB::M.zpad(d.inplace * gain, buffer_size).not_inplace!
          }

          # Ensure the output is at least stereo (Pulseaudio plays nothing for
          # mono output on my system)
          data = data * output.channels if data.length == 1 && output.channels > 1

          output.write(data)
        end

      ensure
        input&.close
      end

      # Returns a String with info to display when playing the given
      # +file_tone_data+.
      def playback_info(file_tone_data)
        case file_tone_data
        when Array
          file_tone_data.map { |ftd| playback_info(ftd) }

        when GraphNode
          filename = file_tone_data.graph.detect { |n| n.respond_to?(:filename) }&.filename
          filename || file_tone_data.to_s

        when String
          "\e[1m#{file_tone_data}\e[22m: #{MB::U.highlight(FFMPEGInput.parse_info(file_tone_data).dig(:format, :tags))}"

        else
          MB::U.highlight(file_tone_data)
        end
      end
    end
  end
end

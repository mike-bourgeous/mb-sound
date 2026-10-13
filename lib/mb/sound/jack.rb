module MB
  module Sound
    # The process's one JACK client (FastAudio's shared client; see
    # ext/mb/sound/fast_audio/mb_jack.h): DeviceOutput, DeviceInput,
    # MIDI::Input, and MIDI::Output put their ports on it whenever JACK is
    # the backend, so a script's outputs, inputs, and MIDI ports are all on
    # one JACK (and PipeWire) node, added at any time, as with the old
    # JackFFI.  Port names follow JackFFI's: out_1, out_2, ... for audio
    # outputs, in_1, ... for audio inputs (numbered across the client), and
    # midi_in/midi_out for MIDI.
    #
    # New audio ports are connected once (to the physical ports, or to ports
    # whose names contain OUTPUT_DEVICE/INPUT_DEVICE; 'none' for no
    # connections); later rewiring (qjackctl, qpwgraph, session managers) is
    # left alone.
    module Jack
      class << self
        # Opens the shared client (named DeviceOutput.client_name) if needed,
        # raising FastAudio::Error if no JACK server answers.
        def open
          FastAudio.jack_open(DeviceOutput.client_name)
        end

        # True if the shared client is open.
        def open?
          !FastAudio.jack_info.nil?
        end

        # The shared client's name (JACK may add a suffix if the name was
        # taken), or nil if it isn't open.
        def client_name
          FastAudio.jack_info&.dig(:client_name)
        end

        # The shared client's :client_name, :sample_rate, :buffer_size,
        # :cycles, :skipped_cycles, and :repeated_cycles, or nil if it isn't
        # open.  An asynchronous server (jackd without --sync) skips cycles
        # for a client that is late, losing what other clients sent it then,
        # or calls it twice for one cycle (MIDI::Input drops the repeated
        # messages, DeviceInput the repeated audio, and DeviceOutput plays
        # the repeated cycle's period once).
        def info
          FastAudio.jack_info
        end

        # True once an audio output or input has warned about a repeated
        # JACK cycle (see #warn_audio_repeats).
        attr_accessor :audio_repeats_reported

        # Says once per process that JACK ran a cycle twice for an audio
        # output or input (+what+, e.g. 'audio output rspec:out_1'), which
        # +handled+ the repeat (e.g. 'played 3 repeated cycles once').
        # Called by DeviceOutput#write and DeviceInput#read.
        def warn_audio_repeats(what, handled)
          return if audio_repeats_reported

          self.audio_repeats_reported = true
          skipped = info&.dig(:skipped_cycles)
          warn "JACK ran a cycle twice for #{what}: the server is asynchronous and this client " \
            "was late, so it #{handled}.  The #{skipped || 'unknown number of'} cycles it skipped " \
            'are gaps in the audio.  `jackd --sync` or a lighter load avoids this ' \
            '(MB::Sound::Jack.info counts them).'
        end

        # Closes the shared client (its outputs and inputs stop).
        def close
          FastAudio.jack_close
        end

        # Returns +count+ free port names: "#{prefix}_N" numbered after the
        # highest number in use on the client (as JackFFI numbered ports),
        # or +prefix+ itself for a single unnumbered port (e.g. 'midi_in',
        # then 'midi_in_2').
        def port_names(prefix, count, numbered: true)
          open
          taken = FastAudio.jack_ports("^#{Regexp.escape(client_name)}:", nil, 0).map { |n| n.split(':', 2).last }

          if !numbered && count == 1 && !taken.include?(prefix)
            return [prefix]
          end

          # The unnumbered name counts as 1 (midi_in, then midi_in_2)
          used = taken.filter_map { |n| n[/\A#{Regexp.escape(prefix)}_(\d+)\z/, 1]&.to_i }
          used << 1 if !numbered && taken.include?(prefix)
          first = (used.max || 0) + 1
          Array.new(count) { |i| "#{prefix}_#{first + i}" }
        end

        # Connects new +ports+ (full names) once: audio outputs (+output+
        # true) to playback ports, inputs from capture ports.  +device+ nil
        # or 'default' means the physical ports, 'none' no connections, and
        # anything else the ports whose names contain it (ignoring case).
        # Port i goes to the i-th match; extra ports stay unconnected.
        def connect(ports, device, output:, midi: false)
          return [] if device.to_s == 'none'

          flags = output ? FastAudio::JACK_PORT_IS_INPUT : FastAudio::JACK_PORT_IS_OUTPUT
          targets =
            if device.nil? || device.to_s.empty? || device.to_s == 'default'
              FastAudio.jack_ports(nil, midi, flags | FastAudio::JACK_PORT_IS_PHYSICAL)
            else
              FastAudio.jack_ports(nil, midi, flags).select { |n| n.downcase.include?(device.to_s.downcase) }
            end

          ports.zip(targets).filter_map { |port, target|
            next unless target
            ok = output ? FastAudio.jack_connect(port, target) : FastAudio.jack_connect(target, port)
            warn "Could not connect JACK port #{port} to #{target}" unless ok
            target if ok
          }
        end

        # The full names of the ports connected to +port+.
        def connections(port)
          FastAudio.jack_connections(port)
        end
      end
    end
  end
end

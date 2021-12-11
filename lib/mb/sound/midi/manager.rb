require 'nibbler'

module MB
  module Sound
    module MIDI
      # Creates a MIDI input port and reads MIDI data from jackd using
      # MB::Sound::JackFFI, smooths control values using
      # MB::Sound::MIDI::Parameter, and sends smoothed parameter data to
      # callbacks.  The #update method should be called 60 times per second, or
      # whatever value was given to the update_rate constructor parameter.
      class Manager
        attr_reader :update_rate, :channel, :cc

        # Transposes note events received via #on_note (but not raw events via
        # #on_event).  This may be fractional for use with VoicePool.
        attr_accessor :transpose

        # Initializes a MIDI manager that parses MIDI data from jackd and sends
        # smoothed control values to callbacks when #update is called.
        #
        # :jack - An instance of MB::Sound::JackFFI (e.g. to customize the
        #         client name)
        # :input - An optional JackFFI (or compatible) MIDI input object.
        #          +:port_name+ and +:connect+ will be ignored if +:input+ is
        #          specified.
        # :port_name - The name of the input port to create (e.g. if multiple
        #              MIDI managers will be used in one program)
        # :connect - The name or type of MIDI port to which to try to connect,
        #            or nil to leave the input port unconnected.
        # :update_rate - How often the #update method will be called.  This is
        #                used to configure parameter smoothing.
        # :channel - The *zero-indexed* MIDI channel to listen on from 0 to 15,
        #            or nil to receive all channels.  Non-channel messages will
        #            always be received.  Drums are usually on channel 10, so
        #            pass 9 to listen to the drum channel, for example.
        def initialize(jack: MB::Sound::JackFFI[], input: nil, port_name: 'midi_in', connect: nil, update_rate: 60, channel: ENV['CHANNEL']&.to_i)
          @parameters = {}
          @event_callbacks = []
          @note_callbacks = []
          @update_rate = update_rate
          @channel = channel

          @cc = Array.new(128)
          @cc_thresholds = {}

          @jack = jack
          @midi_in = input || @jack.input(port_type: :midi, port_names: [port_name], connect: connect)
          @m = Nibbler.new

          @transpose = ENV['TRANSPOSE']&.to_i || 0
        end

        # If the input is a JackFFI MIDI input, returns an Array of Strings
        # with the names of ports connected to the MIDI input.  If the input is
        # a MIDI file, returns the MIDI filename in an Array.  Otherwise,
        # returns the input in String form using String interpolation.
        def connections
          case @midi_in
          when MB::Sound::MIDI::MIDIFile
            [@midi_in.filename]

          when MB::Sound::JackFFI::Input
            @midi_in.connections.flatten

          else
            "#{@midi_in}"
          end
        end

        # Closes the MIDI input port created for this MIDI manager.
        def close
          @midi_in.close
          @midi_in = nil
        end

        # Adds a callback to receive raw MIDI events.
        def on_event(&callback)
          @event_callbacks << callback
        end

        # Adds a callback that receives only the first CC event each time a CC
        # rises above the given threshold.  The callback will be called with
        # (index, value, true) each time the rising threshold is crossed
        # upward.  If a +falling_threshold+ is also specified, then the
        # callback will be called with (index, value, false) when the falling
        # threshold is crossed downward after the rising threshold was met.
        def on_cc_threshold(index, rising_threshold, falling_threshold = nil, description: nil, &callback)
          raise 'Falling threshold must be <= rising threshold' if falling_threshold && falling_threshold > rising_threshold

          @cc_thresholds[index] ||= []
          @cc_thresholds[index] << {
            rising_threshold: rising_threshold,
            falling_threshold: falling_threshold,
            active: false,
            callback: callback,
            description: description
          }

          nil
        end

        # Adds a callback to the given MIDI CC +index+.  See #on_midi.
        def on_cc(index, range: 0.0..1.0, default: nil, filter_hz: 15, max_rise: nil, max_fall: nil, description: nil, &callback)
          template = MIDIMessage::ControlChange.new(@channel, index)
          on_midi(
            template,
            range: range,
            default: default,
            filter_hz: filter_hz,
            max_rise: max_rise,
            max_fall: max_fall,
            description: description,
            &callback
          )
        end

        # Adds a callback to receive pitch bend values.  See #on_midi.
        def on_bend(range: 0.0..1.0, default: nil, filter_hz: 15, max_rise: nil, max_fall: nil, description: nil, &callback)
          template = MIDIMessage::PitchBend.new(@channel, 0)
          on_midi(
            template,
            range: range,
            default: default,
            filter_hz: filter_hz,
            max_rise: max_rise,
            max_fall: max_fall,
            description: description,
            &callback
          )
        end

        # Calls the callback with (note_number, velocity, on) whenever a note
        # on or note off event is received.  The note number received may be
        # fractional if #transpose is fractional.
        def on_note(&callback)
          @note_callbacks << callback
        end

        # Calls the callback with the program number whenever a program change
        # event is received.
        def on_program(&callback)
          template = MIDIMessage::ProgramChange.new(@channel, 0)
          on_midi(template, range: 0..127, default: 0, filter_hz: 100, max_rise: 12700, max_fall: 12700, &callback)
        end

        # Adds a callback to receive smoothed values in the given +:range+ for
        # the given MIDI message template.
        #
        # See MB::Sound::MIDI::Parameter#initialize for a description of the
        # parameters.
        def on_midi(message_template, range: 0.0..1.0, default: nil, filter_hz: 15, max_rise: nil, max_fall: nil, description: nil, &callback)
          raise 'A callback must be given to #on_midi' unless block_given?

          # TODO: Allow sampling parameters in chunks at audio rate, e.g. for
          # smoothing oscillator parameters per-sample instead of per-block
          new_parameter = MB::Sound::MIDI::Parameter.new(
            message: message_template,
            range: range,
            default: default,
            max_rise: max_rise,
            max_fall: max_fall,
            filter_hz: filter_hz,
            update_rate: @update_rate,
            description: description
          )
          @parameters[message_template.class] ||= {}

          # TODO: Why is this an array?  Only one callback is possible here.
          @parameters[message_template.class][new_parameter] = []
          @parameters[message_template.class][new_parameter] << callback

          case message_template
          when MIDIMessage::ControlChange
            # FIXME: this will overwrite previous parameters, allowing only one parameter per CC
            @cc[message_template.index] = new_parameter
          end

          nil
        end

        # Runs one update cycle.  This should be called 60 times per second, or
        # whatever value was given to the constructor's update_rate parameter.
        #
        # Reads MIDI data, updates parameters, and sends current parameter
        # values to all callbacks.
        def update(blocking: false)
          @m.clear_buffer

          while data = @midi_in.read(blocking: blocking)&.[](0)
            events = [@m.parse(data.bytes)].flatten.compact rescue []

            events.each do |e|
              next if @channel && e.respond_to?(:channel) && e.channel != @channel

              notify_event_cbs(e)

              next unless params = @parameters[e.class]
              params.each do |p, _|
                p.notify(e)
              end
            end
          end

          @parameters.each do |_, params|
            params.each do |p, _|
              notify_parameter_cbs(p)
            end
          end

          nil
        end

        # Returns a String containing an XML controller definition compatible
        # with the Sony/MAGIX ACID music software.
        def to_acid_xml(name: File.basename($0))
          require 'builder'

          params = @parameters.values.flat_map(&:keys)
          thresholds = @cc_thresholds.keys

          # TODO: What happens if there are duplicate CCs in the XML?
          # TODO: Will ACID work with UNIX line endings?

          xml = Builder::XmlMarkup.new(indent: 2)
          xml.instruct!
          xml.parammap(mapname: name, ver: 1, summary: '', params: params.length + thresholds.length) do |m|
            params.each do |p|
              p.to_acid_xml(m)
            end

            thresholds.each do |t|
              cc_threshold_to_acid_xml(t, xml: m)
            end
          end

          xml.target!

        rescue LoadError => e
          raise 'The Builder gem is required to generate ACID controller map XML'
        end

        private

        def notify_event_cbs(event)
          @event_callbacks.each do |cb|
            begin
              cb.call(event)
            rescue => e
              # TODO: use a logging facility
              STDERR.puts "Error in MIDI event callback #{cb}: #{e}\n\t#{e.backtrace.join("\n\t")}"
            end
          end

          case event
          when MIDIMessage::NoteOn, MIDIMessage::NoteOff
            @note_callbacks.each do |cb|
              begin
                cb.call(event.note + @transpose, event.velocity, event.is_a?(MIDIMessage::NoteOn))
              rescue => e
                STDERR.puts "Error in MIDI note callback #{cb}: #{e}\n\t#{e.backtrace.join("\n\t")}"
              end
            end

          when MIDIMessage::ControlChange
            @cc_thresholds[event.index]&.each do |cb|
              begin
                if !cb[:active] && event.value >= (cb[:rising_threshold] || cb[:falling_threshold])
                  cb[:active] = true
                  cb[:callback].call(event.index, event.value, true) if cb[:rising_threshold]

                elsif cb[:active] && event.value < (cb[:falling_threshold] || cb[:rising_threshold])
                  cb[:active] = false
                  cb[:callback].call(event.index, event.value, false) if cb[:falling_threshold]
                end
              rescue => e
                STDERR.puts "Error in MIDI CC threshold callback #{cb}: #{e}\n\t#{e.backtrace.join("\n\t")}"
              end
            end
          end
        end

        def notify_parameter_cbs(parameter)
          value = parameter.value

          @parameters[parameter.message.class][parameter].each do |cb|
            begin
              cb.call(value)
            rescue => e
              # TODO: use a logging facility
              STDERR.puts "Error in MIDI parameter callback #{cb} for #{parameter.message}: #{e}\n\t#{e.backtrace.join("\n\t")}"
            end
          end
        end

        def cc_threshold_to_acid_xml(index, xml:)
          raise "No threshold at index #{index}???" if @cc_thresholds[index].nil? || @cc_thresholds[index].empty?

          desc = @cc_thresholds[index].map { |v| v[:description] }.compact[0]

          cc_name = MIDIMessage::Constant::Group.find('Control Change').find_by_value(index)&.key
          name = desc || "CC Switch #{index}#{cc_name ? " (#{cc_name})" : ''}"

          xml.param(name: name) do |p|
            p.flags do |f|
              f.flag('DEFAULT')
              f.flag('ACTIVE')
              f.flag('LOCAL')
              f.flag('SWITCH')
            end

            p.ChannelMask(65535)

            p.MIDIMsg(176)

            p.ccMsg(index)

            p.CurveType('HOLD')
            p.CurveMask do |c|
              c.curve('HOLD')
            end

            p.Min(0)
            p.Max(127)
            p.Neutral(0)
          end
        end
      end
    end
  end
end

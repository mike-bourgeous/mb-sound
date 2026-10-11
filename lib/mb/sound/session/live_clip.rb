module MB
  module Sound
    class Session
      class MidiInput
        # Live MIDI input dressed as a clip, so a track's patch (a block
        # that builds a graph from a clip) can play what is played on the
        # keyboard: armed tracks monitor their input through it (see
        # Arrangement#arm).  It has the clip output methods (#notes, #tone,
        # #amp_env, #synth, ...), each on a new tap of the input (see
        # MidiInput#stream), and #transpose; other clip methods raise.  Unlike a
        # Clip's, its Notes apply the sustain pedals.
        class LiveClip
          # The Session::MidiInput played.
          attr_reader :input

          def initialize(input, transforms = [])
            @input = input
            @transforms = transforms.freeze
          end

          # A new MIDI::Stream of the input (with any #transpose applied).
          def stream
            @transforms.reduce(@input.stream) { |s, (m, args, kwargs)| s.public_send(m, *args, **kwargs) }
          end

          # A MB::Sound::Notes on a new #stream (see Sequence::Clip#notes).
          def notes(transport: nil)
            MB::Sound::Notes.new(stream, sustain: true)
          end

          # The input transposed (see MIDI::Stream#transpose).
          def transpose(step, scale: nil, root: nil)
            self.class.new(@input, @transforms + [[:transpose, [step], { scale: scale, root: root }]])
          end

          %i[trigger gate number hz freq].each do |m|
            define_method(m) { |transport: nil| notes.public_send(m) }
          end
          alias tone hz
          alias pitch hz
          alias frequency freq

          # See Sequence::Clip#velocity.
          def velocity(range: 0.0..1.0, transport: nil)
            v = notes.velocity
            range == (0.0..1.0) ? v : v * (range.end - range.begin) + range.begin
          end

          # See Sequence::Clip#period.
          def period(transport: nil)
            1 / freq
          end

          %i[env amp_env fm_env filter_env].each do |m|
            define_method(m) { |attack = nil, decay = nil, sustain = nil, release = nil, gm: false, transport: nil, **options|
              notes.public_send(m, attack, decay, sustain, release, gm: gm, **options)
            }
          end
          alias envelope env
          alias amp_envelope amp_env
          alias fm_envelope fm_env
          alias filt_env filter_env
          alias filter_envelope filter_env

          # A polyphonic Synth playing the input (see Sequence::Clip#synth).
          def synth(voices: 2, **options, &block)
            raise ArgumentError, 'Pass a block that builds a graph for one voice' unless block
            s = MB::Sound::Synth.new(stream, voices: voices, **options, &block)
            s.outputs.length > 1 ? GraphNode::Channels.new(s.outputs) : s
          end

          def looping?
            true
          end

          def named?
            false
          end

          def name
            nil
          end

          def to_s
            "live #{@input}"
          end

          def method_missing(name, *args, **kwargs, &block)
            if Sequence::Clip.method_defined?(name)
              raise NoMethodError, "#{name} isn't available on live MIDI input (a track's patch monitoring an armed track gets live input in place of a clip)"
            end
            super
          end

          def respond_to_missing?(name, include_private = false)
            super
          end
        end
      end
    end
  end
end

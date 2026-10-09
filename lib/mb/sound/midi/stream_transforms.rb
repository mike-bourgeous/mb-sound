module MB
  module Sound
    module MIDI
      # MIDI transforms and generators (the MIDI transforms project,
      # 2026-10-10): methods on Streams that return new Streams, mirrored on
      # MB::Sound::Notes (returning a Notes with the same pedal setting, so
      # `midi.echo(...)` works on the console's live input) and on
      # Sequence::Clip (returning a Stream of the clip; Clip#bake turns a
      # transformed stream back into a Clip).  Chains read left to right:
      #
      #     midi.echo(3.n16, 3, pitch: 7.st, velocity: 0.7).synth(voices: 16) { |v| ... }
      #     riff.arp(:up, 16, octaves: 2).synth { |v| ... }
      #
      # Every transform runs once for all readers of its stream.
      class Stream
        # Methods that Notes and Clip mirror (see MB::Sound::Notes and
        # Sequence::Clip).  Stream-only helpers (#synth, #notes) aren't
        # listed.
        TRANSFORMS = [
          :channel, :keys, :transpose, :velocity_curve, :bend_range,
          :echo,
        ].freeze

        # Transforms that Sequence::Clip mirrors, returning Streams of the
        # clip (user decision 8, 2026-10-09: `clip.echo(...)` is a Stream
        # whose echoes ring past loop points; `clip.bake(echo(...))` is a
        # Clip).  Clip has its own #transpose and editing methods.
        CLIP_TRANSFORMS = [
          :echo,
        ].freeze

        # Returns a stream that repeats each note +count+ times, +delay+
        # apart (seconds, a Length, or a Duration such as 3.n16), each
        # repeat moved by +:pitch+ and scaled by +:velocity+ (see
        # Transform::Echo):
        # - +:pitch+: a step in scale degrees of +:scale+ (chromatic by
        #   default, so degrees are semitones), an Interval, or an Array of
        #   steps cycled through (`[4, 3, 5]` climbs a major triad).
        # - +:velocity+: multiplier per repeat (e.g. 0.7, or -3.db).
        # - +:gate+: nil (default) for repeats as long as the played note,
        #   a fraction of the delay, or a Length.
        # - +:dry+: false leaves out the played notes.
        # - +:scale+/+:root+: a Scale, a name (:minor), or an Array of
        #   offsets, with its root (:a, A3).
        # - +:overlap+: :retrigger (default) or :stack for same-key notes;
        #   +:jump+: :ring (default, echoes ring on through seeks and swaps)
        #   or :cut (see Transform::Scheduled).
        # The block, if given, gets each echo's note-on Event and its index
        # (1..count) and returns an Event (e.g. `e.transpose(12)`,
        # `e.with_velocity(...)`) or nil to skip that echo.
        #
        #     stream.echo(3.n16, 4, pitch: 7.st, velocity: 0.7)
        #     stream.echo(1.n16, 11, pitch: 2, scale: :minor, root: :a, velocity: 0.86)
        #     stream.echo(1.n8.dotted, 8) { |e, i| i.odd? ? e.transpose(12) : e }
        def echo(delay, count = 3, **options, &block)
          Stream.new(Transform::Echo.new(self, delay, count, **options, &block))
        end

        # A MB::Sound::Notes on this stream (see Notes.new), e.g. for a
        # mono voice: `n = stream.notes; play n.hz.saw * n.amp_env`.
        def notes(sustain: false)
          MB::Sound::Notes.new(self, sustain: sustain)
        end

        # A polyphonic MB::Sound::Synth playing this stream (see Synth.new;
        # Synth applies the sustain pedals).  Returns Channels for
        # multichannel voices, like Clip#synth.
        #
        #     clip.echo(3.n16, 4).synth(voices: 12) { |v| v.hz.saw * v.amp_env }
        def synth(voices: 8, **options, &block)
          raise ArgumentError, 'Pass a block that builds a graph for one voice' unless block

          s = MB::Sound::Synth.new(self, voices: voices, **options, &block)
          s.outputs.length > 1 ? GraphNode::Channels.new(s.outputs) : s
        end
      end
    end
  end
end

module MB
  module Sound
    module Sequence
      class Clip
        # Stream transforms that clips play through (each returns a
        # MIDI::Stream of a new #stream of this clip; Clip#bake runs one
        # offline into a Clip).  Clip's own #transpose, #ratchet, etc.
        # return Clips.
        MIDI::Stream::CLIP_TRANSFORMS.each do |name|
          define_method(name) do |*args, **kwargs, &block|
            stream.public_send(name, *args, **kwargs, &block)
          end
        end
      end
    end
  end
end

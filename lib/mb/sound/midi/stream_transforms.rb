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
          :echo, :arp, :chord, :strum, :humanize, :quantize, :snap,
          :select, :reject, :velocities, :map_notes, :vel, :rechannel, :to_channel,
          :note_length, :len, :shift, :through,
        ].freeze

        # Transforms that Sequence::Clip mirrors, returning Streams of the
        # clip (user decision 8, 2026-10-09: `clip.echo(...)` is a Stream
        # whose echoes ring past loop points; `clip.bake(echo(...))` is a
        # Clip).  Clip has its own #transpose and editing methods.
        CLIP_TRANSFORMS = [
          :echo, :arp, :strum, :chord, :snap, :through,
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

        # Returns an arpeggiator stream: the held keys played one at a time,
        # one every +rate+ (an Integer note division like 16, a Duration
        # like 1.n16.t, or Rational whole notes), locked to the session
        # timeline's grid (see Transform::Arp).  +mode+ is one of
        # Transform::Arp::MODES (:up, :down, :updown, :downup, :up_down,
        # :down_up, :played, :random, :converge, :diverge, :pinky, :thumb,
        # :chord).  Options:
        # - +:octaves+ (1) copies of the held notes, each +:step+ higher (an
        #   octave by default; scale degrees or an Interval).
        # - +:gate+ (0.5) note length as a fraction of a step.
        # - +:velocity+: nil (the keys'), a number, or an Array of factors
        #   cycled per step (accents).
        # - +:swing+ (0.5 straight; 0.66 for a triplet feel).
        # - +:latch+: keep playing released keys until the next new chord.
        # - +:start+: :grid (default; steps on the timeline grid, a key
        #   pressed between steps waits for the next) or :key (Juno-style:
        #   the clock starts at the first key).
        # - +:steps+: an Array of pitch offsets cycled per step (scale
        #   degrees of +:scale+/+:root+ or Intervals), e.g. [0, 0, 12, 7].
        # - +:seed+ for :random, +:overlap+/+:jump+ (see Scheduled).
        #
        #     midi.arp(:up, 16, octaves: 2)
        #     midi.arp(:updown, 1.n16.t, gate: 0.9, latch: true)
        #     riff.arp(:converge, 32, steps: [0, 7, 12], swing: 0.6)
        def arp(mode = :up, rate = 16, **options)
          Stream.new(Transform::Arp.new(self, mode, rate, **options))
        end

        # Adds notes to each played note: a chord name (Transform::Chord::SHAPES,
        # e.g. :min7, :add9, :power; semitones above the note) or pitch
        # steps (scale degrees of +:scale+, semitones by default, or
        # Intervals).  Added notes end with the played note; +:velocity+
        # scales theirs.
        #
        #     midi.chord(:min7)
        #     midi.chord(2, 4, scale: :major, root: :c)   # diatonic triads from one finger
        #     midi.chord(-1.oct)                          # octave doubling below
        def chord(*steps, scale: nil, root: nil, velocity: 1, **options)
          Stream.new(Transform::Chord.new(self, steps, scale: scale, root: root, velocity: velocity, **options))
        end

        # Spreads notes that start together (within +:window+ of the first;
        # 0 = exactly together, as in clips) over +spread+ (a length from
        # the first note to the last), in +direction+: :down (low to high,
        # a downstroke), :up, :alternate (down, up, ...), :random (seeded),
        # or :played.  Notes only move later (user decision 7: no
        # lookahead), so live chords need a +:window+ (e.g. 20.ms) and are
        # delayed by it.  +:velocity+ multiplies each later note's velocity.
        #
        #     chords.strum(40.ms)
        #     midi.strum(30.ms, :alternate, window: 20.ms)
        def strum(spread = 0.03, direction = :down, **options)
          Stream.new(Transform::Strum.new(self, spread, direction, **options))
        end

        # Random timing and velocity offsets per note, repeatable from
        # +:seed+ (drawn from MB::Sound's random seed by default).  Notes
        # only move later, by up to +time+ (user decision 7: live input
        # can't move earlier); +:velocity+ is the largest change as a
        # fraction (0.1 = up to 10% softer or louder).  For clips,
        # Sequence::Clip#humanize moves notes both ways.
        def humanize(time = 0.01, velocity: 0, seed: nil, **options)
          Stream.new(Transform::Humanize.new(self, time, velocity: velocity, seed: seed, **options))
        end

        # Moves notes later to the next step of the timeline grid (+grid+ an
        # Integer note division, Duration, or Rational whole notes), or
        # +:amount+ (0..1) of the way there.  Notes more than +:window+
        # before the next step are left alone.  This adds up to one step of
        # latency (honestly: notes can't move earlier live); for clips,
        # Sequence::Clip#quantize moves notes to the nearest step.
        def quantize(grid = 16, amount: 1, window: nil, **options)
          Stream.new(Transform::Quantize.new(self, grid, amount: amount, window: window, **options))
        end

        # Moves notes into a scale: +scale+ a Scale, name, or Array of
        # offsets, with +root+; +:direction+ :nearest (ties down), :down,
        # or :up.
        #
        #     midi.snap(:minor_pentatonic, :a)
        def snap(scale, root = nil, direction: :nearest, **options)
          Stream.new(Transform::Snap.new(self, scale, root: root, direction: direction, **options))
        end

        # Keeps only the notes whose note-on Event the block accepts (their
        # note-offs and poly pressure follow); other events pass through.
        #
        #     midi.select { |e| e.velocity > 0.5 }
        def select(&block)
          Stream.new(Transform::Select.new(self, &block))
        end

        # Drops the notes whose note-on Event the block accepts (see #select).
        def reject(&block)
          Stream.new(Transform::Select.new(self, reject: true, &block))
        end

        # Keeps notes whose velocity (0..1) is in +range+.
        def velocities(range)
          Stream.new(Transform::Select.new(self, name: "velocities(#{range})") { |e| range.cover?(e.velocity) })
        end

        # Changes each note-on with the block, which returns an Event (e.g.
        # `e.transpose(12)`, `e.with_velocity(0.5)`, `e.with_channel(1)`, a
        # later `e.at(e.time + 0.1)`), an Array of Events (several notes),
        # or nil (drop the note).  Note-offs follow each note (same key,
        # channel, and delay); notes never move earlier than played.
        def map_notes(&block)
          Stream.new(Transform::MapNotes.new(self, &block))
        end

        # Every note-on at +velocity+ (0..1).
        def vel(velocity)
          v = MB::M.clamp(velocity.to_f, 0.0, 1.0)
          Stream.new(Transform::VelocityCurve.new(self, ->(_) { v }, name: "vel(#{velocity})"))
        end

        # Moves every channel message to 0-based +channel+ (e.g. to layer a
        # stream onto another synth's channel).  Also #to_channel.
        def rechannel(channel)
          Stream.new(Transform::Rechannel.new(self, channel))
        end
        alias to_channel rechannel

        # Every note lasts +length+ (seconds, a Length, or a Duration) from
        # its note-on, however long the key was held.  Also #len.
        def note_length(length, **options)
          Stream.new(Transform::NoteLength.new(self, length, **options))
        end
        alias len note_length

        # Every event +delay+ later (seconds, a Length, or a Duration).
        def shift(delay, **options)
          Stream.new(Transform::Shift.new(self, delay, **options))
        end

        # Returns [below, at and above]: two streams splitting the notes at
        # +point+ (a Note or note number); channel-wide events go to both.
        #
        #     lo, hi = midi_stream.split(C4)
        def split(point)
          p = point.respond_to?(:number) && !point.is_a?(Numeric) ? point.number.round : Integer(point)
          [keys(0..(p - 1)), keys(p..127)]
        end

        # Interleaves this stream with +others+ (Streams, Clips, Notes, ...)
        # in time order.
        def merge(*others)
          Stream.new(Transform::Merge.new([self, *others]))
        end

        # Returns this stream through +fx+: an unattached chain of
        # transforms (Transform::Spec, from MB::Sound#echo, #arp, ...) or a
        # Proc taking and returning a Stream.
        #
        #     midi.through(echo(3.n16, 3).strum(20.ms))
        def through(fx = nil, &block)
          fx ||= block
          raise ArgumentError, 'Pass a transform chain (e.g. echo(1.n8, 3)) or a block' unless fx
          Stream.for(fx.respond_to?(:apply) ? fx.apply(self) : fx.call(self))
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

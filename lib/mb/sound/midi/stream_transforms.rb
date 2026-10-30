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
        #
        # The feel and clip operations (humanize, quantize, swing, chance,
        # every, legato, ratchet, ghost_chords, transpose, shift; clips also rotate)
        # share their option names and cores with the Clip methods of the
        # same names (midi-consol-1, maintainer decision 1, 2026-10-16:
        # "shared core, two front ends"; see Sequence::Feel): clips know
        # their future, so they may move notes earlier and wrap in loops,
        # while streams only delay.
        TRANSFORMS = [
          :channel, :keys, :transpose, :velocity_curve, :bend_range,
          :echo, :arp, :chord, :strum, :humanize, :quantize, :snap,
          :select, :reject, :velocities, :map_notes, :vel, :rechannel, :to_channel,
          :note_length, :len, :shift, :rotate, :through,
          :swing, :chance, :maybe, :every, :legato, :ratchet, :ghost_chords,
          :degrees, :lock, :groove,
        ].freeze

        # Transforms that Sequence::Clip mirrors, returning Streams of the
        # clip (user decision 8, 2026-10-09: `clip.echo(...)` is a Stream
        # whose echoes ring past loop points; `clip.bake(echo(...))` is a
        # Clip).  Clip has its own #transpose and editing methods.
        CLIP_TRANSFORMS = [
          :echo, :arp, :strum, :chord, :snap, :through, :degrees, :lock,
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
        #   pressed between steps waits for the next), :key (Juno-style:
        #   the clock starts at the first key), or :hybrid (the first step
        #   sounds at the key, later steps on the grid).
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
        # Intervals; +:scale+ and +:root+ go with steps only).  Added notes
        # end with the played note; +:velocity+ scales theirs.
        #
        # The two chords: this transform adds notes relative to each played
        # note (steps count from the note, 0 = itself), while the top-level
        # `chord(:min7, root: :d)` (a quality and +root:+, no +scale:+) is a
        # chord value (Generative::Chord) for probability scales; every
        # other top-level `chord(...)` call is this transform, unattached
        # (see SequenceMethods#chord).  Clip#ghost_chords' degrees count
        # from 1 like Roman numerals, Scale#chord's from 0.
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
        # only move later, by up to +time+ (4 ms by default, the same as
        # Sequence::Clip#humanize, which moves notes both ways; maintainer
        # decision 7, 2026-10-16; 10 ms before); +:velocity+ is the
        # largest change as a fraction (0.1 = up to 10% softer or louder).
        # Live notes have no loop cycles, so there's no +:vary+: every note
        # draws anew.
        def humanize(time = Sequence::Feel::HUMANIZE_TIME, velocity: 0, seed: nil, **options)
          Stream.new(Transform::Humanize.new(self, time, velocity: velocity, seed: seed, **options))
        end

        # Moves notes later to the next step of the timeline grid (+grid+ an
        # Integer note division, Duration, or Rational whole notes), or
        # +:amount+ (0..1) of the way there.  Notes more than +:window+
        # before the next step are left alone.  With +ends: true+ note-offs
        # move to the next step too (a fully quantized note lasts at least
        # a step).  This adds up to one step of latency (honestly: notes
        # can't move earlier live); for clips, Sequence::Clip#quantize
        # (same options) moves notes to the nearest step.
        def quantize(grid = Sequence::Feel::GRID, amount: 1, window: nil, ends: false, **options)
          Stream.new(Transform::Quantize.new(self, grid, amount: amount, window: window, ends: ends, **options))
        end

        # Moves notes onto a feel template's grid positions plus its offsets
        # on the timeline, +amount+ of the way, and scales velocities toward
        # its levels (+velocity:+, by default +amount+), like
        # Sequence::Clip#groove (the same core, Feel.groove_target), except
        # that streams only delay: a note goes to the next step's position
        # (or stays, if that is already behind it).  +template+ is a
        # Sequence::Groove or a Clip to measure one from (+grid:+,
        # +triplets:+).
        #
        #     midi.groove(take.groove, amount: 0.5)
        def groove(template, amount: 1, velocity: nil, grid: Sequence::Feel::GRID, triplets: false, **options)
          template = Sequence::Groove.from_clip(template, grid: grid, triplets: triplets) if template.is_a?(Sequence::Clip)
          Stream.new(Transform::Groove.new(self, template, amount: amount, velocity: velocity, **options))
        end

        # Swing on the timeline grid: within each pair of +grid+ steps (an
        # Integer note division like 16, or a Duration), notes on or after
        # the second step are delayed so it starts at +amount+ of the pair
        # (0.5 straight, 0.58 a light shuffle, 2/3r a triplet feel), the
        # same time warp as Sequence::Clip#swing (note-offs warp too, so
        # lengths follow).  Streams only delay, so amounts start at 0.5.
        #
        #     midi.swing(0.6)
        #     riff.loop.stream.swing(2/3r, 8)
        def swing(amount = Sequence::Feel::SWING, grid = Sequence::Feel::GRID, **options)
          Stream.new(Transform::Swing.new(self, amount, grid, **options))
        end

        # Plays each note with probability +p+ (0..1), decided per note
        # from +:seed+ (see #humanize for seeds).  Alias #maybe.  Clips
        # decide per loop cycle (Sequence::Clip#chance).
        #
        #     midi.chance(0.7)
        def chance(p, seed: nil, **options)
          Stream.new(Transform::Chance.new(self, p, seed: seed, **options))
        end
        alias maybe chance

        # Plays notes only every +n+th bar of the session timeline, from
        # bar +from+ (counting from 1; bars follow the meter map), like
        # Sequence::Clip#every, which counts loop cycles (Elektron's trig
        # conditions: `every(4, from: 4)` plays in bars 4, 8, 12, ...).
        def every(n, from: 1, **options)
          Stream.new(Transform::Every.new(self, n, from: from, **options))
        end

        # Every note lasts +fraction+ of its length (see
        # Sequence::Clip#legato).  Fractions of 1 or more delay note-offs.
        # Fractions under 1 shorten notes that carry a length hint
        # (MIDI::Event#length_hint: notes from clips, arp, echo, ratchet,
        # len), planning their note-offs at the note-on, so no latency is
        # added; notes without a hint (live keys, files) pass through
        # unchanged after one MB::Sound.live_error notice (an error in
        # scripts and specs).  Given a length (a Duration or Length)
        # instead, every note lasts that long, as #note_length / #len.
        #
        #     midi.legato(1.5)
        #     riff.loop.stream.legato(0.5)   # staccato from the clip's lengths
        #     midi.legato(1.n16)     # as len(1.n16)
        def legato(fraction, **options)
          return note_length(fraction, **options) if fraction.is_a?(Sequence::Duration) || fraction.is_a?(Length)
          Stream.new(Transform::Legato.new(self, fraction, **options))
        end

        # Strikes each note up to +count+ times, +:rate+ apart (a Duration
        # such as 1.n32, a Length, or seconds), while it is held: the last
        # hit (or the one sounding when the key comes up) ends with the
        # note.  +:velocity+ as in Sequence::Clip#ratchet (a number, or a
        # Range ramped over the hits).  Clips split each note's length when
        # given no rate; streams need one.
        #
        #     midi.ratchet(4, rate: 1.n32)
        #     midi.ratchet(8, rate: 1.n16.t, velocity: 1.0..0.3)
        def ratchet(count, rate: nil, velocity: nil, **options)
          Stream.new(Transform::Ratchet.new(self, count, rate: rate, velocity: velocity, **options))
        end

        # Moves notes to the nearest tones of a silent chord progression
        # (see Sequence::Clip#ghost_chords for the chords and options), one
        # chord per +:per+ (a Duration; one bar of the timeline's meter
        # map by default), counted from the start of the timeline, so a
        # timeline-aligned loop gets the same chords as with
        # Clip#ghost_chords.  Ties follow the played contour; +:passing+
        # isn't available (a note's length isn't known when it starts).
        # Live input works too: its chords follow the session timeline's
        # bars (maintainer, 2026-10-16, lifting the earlier live_error).
        #
        #     hook.loop.stream.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :a))
        #     midi.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :a))   # keys snap to the bar's chord
        def ghost_chords(*chords, per: nil, scale: nil, root: nil, size: 3, harmonic: false, tie: :contour, passing: nil, **options)
          Stream.new(Transform::GhostChords.new(self, chords, per: per, scale: scale, root: root, size: size, harmonic: harmonic, tie: tie, passing: passing, **options))
        end

        # Moves notes into a scale: +scale+ a Scale, name, or Array of
        # offsets, with +root+; +:direction+ :nearest (ties down), :down,
        # or :up.  Without a scale (or a mode name without a root, or a
        # param giving one) the scale follows the session key (`key :d,
        # :dorian`) at each note.
        #
        # With :chord, every key plays the nearest tone of the current
        # chord instead (MIDI::Lock::Chord): +from:+ a clip of chords, a
        # chord(...) value, chord degrees counted from 1 like ghost_chords
        # (`[1, 4, 5, 1]`, one per +per:+, a bar by default, in the session
        # key), or a param giving one (nil: the key's tonic triad);
        # +extend:+ false (chord tones only), :above (stacked thirds above
        # the chord's top note), or true (extensions everywhere); +avoid:+
        # (true) skips avoid notes; +bass: :root_fifth+ below the chord.
        #
        #     midi.snap(:minor_pentatonic, :a)
        #     midi.snap                         # the session key
        #     midi.snap(:chord, from: chords)   # the chord playing in a clip
        #     midi.snap(:chord, from: [1, 6, 4, 5], extend: :above, bass: :root_fifth)
        def snap(scale = nil, root = nil, direction: :nearest, from: nil, extend: false, avoid: true, bass: nil, per: nil, micro: :mark, **options)
          if scale == :chord
            map = Lock::Chord.new(from: from, extend: extend, avoid: avoid, bass: bass, per: per, micro: micro)
            return Stream.new(Transform::Locked.new(self, map, **options))
          end
          if root.nil? && (scale.nil? || scale.is_a?(Symbol) || scale.is_a?(String) || Param.param?(scale))
            return Stream.new(Transform::Locked.new(self, Lock::ScaleSnap.new(scale, direction: direction, micro: micro), **options))
          end
          Stream.new(Transform::Snap.new(self, scale, root: root, direction: direction, **options))
        end

        # Scale degrees on the keys (MIDI::Lock::Degrees): white keys walk
        # the degrees of +scale+ (the session key by default, a mode name on
        # the key's root, a Scale, or a param giving one).  +layout+ :flow
        # (each white key the next degree from the root on middle C; best
        # for mashing and exotic scales) or :fit (the root on every C; 8-12
        # note scales take black keys too); +black+ :passing (the note
        # between the neighbouring degrees: the middle of a whole step, just
        # below the upper note of wider gaps, silent for half steps, the
        # cents midpoint in cents scales), :silent, or :lower.
        #
        #     midi.degrees                       # the session key, flowing
        #     midi.degrees(:minor_pentatonic, layout: :fit)
        #     midi.degrees(scale(:dorian, :d), black: :silent)
        def degrees(scale = nil, layout: :flow, black: :passing, micro: :mark, **options)
          Stream.new(Transform::Locked.new(self, Lock::Degrees.new(scale, layout: layout, black: black, micro: micro), **options))
        end

        # The scale or chord lock by intent (MIDI::Lock::Style): :mash
        # (degrees flowing, black keys silent), :play (degrees fitted to the
        # octave, black keys passing notes), :along (nearest scale note),
        # :chord (chord tones, extend :above), :off; keyword overrides
        # (`lock(:chord, extend: true)`, `lock(:play, scale: :lydian)`).
        # The style may be a param (`knob(:style).choose(:mash, :play)`).
        # The console's `lock` (KeyMethods#lock) does the same for live
        # MIDI and the virtual keyboard.
        #
        #     keys.lock(:play)
        #     midi.lock(:chord, from: chords, bass: :root_fifth)
        def lock(style = :play, **options)
          transform = options.slice(*Transform::Locked::OPTIONS)
          Stream.new(Transform::Locked.new(self, Lock::Style[style, **options.except(*Transform::Locked::OPTIONS)], **transform))
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

        # Every note-on at +velocity+ (clamped to 0..1, like Clip#vel;
        # Sequence::Feel.fixed_velocity).
        def vel(velocity)
          v = Sequence::Feel.fixed_velocity(velocity)
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

        # Every event +delay+ later (seconds, a Length, or a Duration; not
        # negative: a live stream can't play notes before they arrive).
        # Sequence::Clip#shift is the clip version (which may also move
        # notes earlier, dropping what leaves the clip).
        def shift(delay, **options)
          Stream.new(Transform::Shift.new(self, delay, **options))
        end

        # Streams can't rotate: wrapping notes around a loop needs notes a
        # live stream hasn't played yet.  Raises (through
        # MB::Sound.live_error: in live mode it warns and returns the
        # stream unchanged), pointing to #shift (a delay) and
        # Sequence::Clip#rotate.
        def rotate(_amount = nil, **_options)
          MB::Sound.live_error(ArgumentError.new(Stream.rotate_message)) || self
        end

        # The explanation #rotate raises with (also for unattached chains,
        # Transform::Spec#rotate).
        def self.rotate_message
          "a live stream can't rotate (wrapping notes around a loop needs notes that haven't played yet) " \
            '(did you mean shift?): stream.shift(1.n8) delays every note; clips rotate (clip.rotate(1.n8))'
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

        # Merges +other+ (a Stream, Clip, or Notes) into this stream, like
        # #merge: note streams layer with + as signals do (`&` stays free
        # for another meaning; Clip#& layers clips).
        #
        #     (bass.stream + lead.stream).synth { |v| ... }
        def +(other)
          merge(other)
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

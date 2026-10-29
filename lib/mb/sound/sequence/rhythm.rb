module MB
  module Sound
    module Sequence
      # A rhythm template (midi-import-1, 2026-10-28; maintainer: "use its
      # rhythm as a rhythm template", meaning (a)): which steps of a clip
      # play, how long, how loud, accented and slid, without pitches, so
      # other pitches can be poured in.  Clip#rhythm takes one from any
      # clip (an imported MIDI phrase, a seq, a grid row, a capture);
      # notes that start together are one hit (a chord's rhythm).
      #
      #     groove = midi_clip('reese.mid', track: 1, bars: 2).rhythm
      #     groove.notes(C1, F1, A1, G1)          # cycling, one pitch per hit
      #     groove.notes(C2, [C3, Eb3, G3], nil)  # chords; nil rests a hit
      #     groove.pitches(0, 2, 4, 3, scale: scale(:minor, :a))  # scale degrees
      #     groove.to_clip(36)                    # every hit on one note
      #
      # Rhythms are values (their parts frozen); they print as `clip.rhythm` through
      # recipes, else as `rhythm([start, length, velocity, { marks }], ...,
      # length:, loop:)` (MB::Sound#rhythm).
      class Rhythm
        include Enumerable

        # One hit: start and length (whole notes), velocity (0..1), and the
        # accent and slide marks.
        Hit = Data.define(:start, :length, :velocity, :accented, :slid)

        # Marks a #rhythm row's Hash may give.
        MARKS = %i[accented slid].freeze

        attr_reader :hits, :length

        # The hits of +clip+ (its first cycle for clips that vary per
        # cycle), one per start time: the longest length, the loudest
        # velocity, accented or slid if any note there is.
        def self.from_clip(clip)
          raise ArgumentError, "A rhythm comes from a clip (got #{clip.class})" unless clip.is_a?(Clip)
          hits = clip.events_for(0).select { |e| e.start >= 0 }.group_by(&:start).sort_by(&:first).map { |start, evs|
            Hit.new(start: start, length: evs.map(&:length).max, velocity: evs.map(&:velocity).max,
                    accented: evs.any?(&:accented), slid: evs.any?(&:slid))
          }
          new(hits, length: clip.length, loop: clip.looping?)
        end

        def initialize(hits, length:, loop: false)
          length = length.whole_notes if length.is_a?(Duration)
          raise ArgumentError, "A rhythm's length is whole notes (got #{length.inspect})" unless length.is_a?(Numeric) && length.real? && !length.is_a?(Float) && length >= 0
          raise ArgumentError, 'A looping rhythm needs a positive length' if loop && length <= 0
          @hits = hits.sort_by(&:start).freeze
          @length = length.to_r
          @loop = !!loop
          @graph_recipe = nil # (not frozen: recipes remember the call that made it)
        end

        # True if clips made from this rhythm loop.
        def looping?
          @loop
        end

        # The number of hits.
        def count(*args, &block)
          return @hits.length if args.empty? && block.nil?
          super
        end

        def each(&block)
          @hits.each(&block)
        end

        # The hits' start times (whole notes).
        def onsets
          @hits.map(&:start)
        end

        # A Clip playing +pitches+ on the hits in turn, cycling (more hits
        # than pitches repeat them; more pitches than hits are left over):
        # Notes or note numbers, Arrays for chords, nil or Rest to leave a
        # hit silent, Tie to repeat the pitch before, or a Clip or Seq whose
        # notes (chords grouped by start) are taken in order.  Lengths,
        # velocities (or +velocity:+ for all), accents, and slides come from
        # the hits.
        def notes(*pitches, velocity: nil)
          list = Rhythm.pitch_list(pitches)
          raise ArgumentError, 'Rhythm#notes needs pitches (Notes, numbers, Arrays for chords, nil for rests)' if list.empty?
          raise ArgumentError, "velocity: is from 0 to 1 (got #{velocity.inspect})" unless velocity.nil? || (velocity.is_a?(Numeric) && velocity.between?(0, 1))

          prev = nil
          events = @hits.each_with_index.flat_map { |h, i|
            p = list[i % list.length]
            p = prev if p == :tie
            prev = p
            Array(p).map { |n|
              Event.new(start: h.start, length: h.length, value: n, velocity: velocity || h.velocity, accented: h.accented || nil, slid: h.slid || nil)
            }
          }
          Clip.new(events, length: @length, loop: @loop)
        end

        # A Clip playing scale degrees (counted from 0, Integers; Arrays
        # for chords, nil for rests) of +scale+ (a Scale or anything
        # MB::Sound#scale takes; the session key's scale by default) on the
        # hits in turn, cycling (see #notes).
        def pitches(*degrees, scale: nil, velocity: nil)
          raise ArgumentError, 'Rhythm#pitches needs scale degrees (Integers, Arrays for chords, nil for rests)' if degrees.empty?
          s = scale.is_a?(MB::Sound::Scale) ? scale : (scale.nil? ? MB::Sound.scale : MB::Sound.scale(scale))
          notes(*degrees.map { |d| Rhythm.degree_pitch(d, s) }, velocity: velocity)
        end

        # A Clip with every hit on +note+ (middle C by default; 36 for a
        # kick).
        def to_clip(note = 60)
          notes(note)
        end

        # The rhythm as a step string on a +division+ grid ('X' accented, 'x'
        # a hit, '-' held, '.' rest), or nil if a hit is off the grid.
        def steps(division = 16)
          step = Duration.whole_notes(division)
          n = (@length / step).ceil
          return nil unless @hits.all? { |h| (h.start / step).denominator == 1 }
          s = Array.new(n, '.')
          @hits.each do |h|
            i = (h.start / step).to_i
            next if i >= n
            held = (h.length / step).ceil
            (1...held).each { |k| s[i + k] = '-' if i + k < n && s[i + k] == '.' }
            s[i] = h.accented ? 'X' : 'x'
          end
          s.join
        end

        def ==(other)
          other.is_a?(Rhythm) && other.hits == @hits && other.length == @length && other.looping? == @loop
        end
        alias eql? ==

        def hash
          [@hits, @length, @loop].hash
        end

        def to_s
          grid = steps
          body = grid ? grid : @hits.map { |h| "#{MB::M.sigfigs(h.start.to_f, 4)}" }.join(' ')
          "Rhythm(#{Duration.format(@length)}#{' loop' if @loop}, #{@hits.length} hits: #{body})"
        end

        def inspect
          "#<#{self}>"
        end

        # The `rhythm(...)` text that makes this rhythm (MB::Sound#rhythm).
        def to_ruby
          writer = GraphNode::Recipe::RubyWriter.new(nil)
          rows = @hits.map { |h|
            marks = MARKS.select { |m| h.public_send(m) }.to_h { |m| [m, true] }
            "[#{[h.start, h.length, h.velocity].map { |x| writer.literal(x) }.join(', ')}#{", #{writer.literal(marks)}" unless marks.empty?}]"
          }
          kw = ["length: #{writer.literal(@length)}"]
          kw << 'loop: true' if @loop
          "rhythm(#{(rows + kw).join(', ')})"
        end

        # Pitches for #notes: each argument as a note number, an Array of
        # them, nil (a rest), or :tie; Clips and Seqs give their notes.
        def self.pitch_list(items)
          items.flat_map { |p|
            case p
            when Clip
              p.events_for(0).group_by(&:start).sort_by(&:first).map { |_, evs| evs.length == 1 ? note_value(evs[0].value) : evs.map { |e| note_value(e.value) } }
            else
              [pitch_value(p)]
            end
          }
        end

        def self.pitch_value(p)
          case p
          when nil then nil
          when Seq::Step then p.tie ? :tie : (p.value.nil? ? nil : note_value(p.value))
          when Array then p.map { |x| note_value(x) }
          else note_value(p)
          end
        end

        def self.note_value(v)
          v = v.value if v.is_a?(Seq::Step)
          return v.number if v.is_a?(MB::Sound::Note)
          return v if v.is_a?(Numeric) && v.real? || v.is_a?(MB::Sound::Pitch)
          raise ArgumentError, "Rhythm pitches are Notes, numbers, Arrays for chords, or nil for rests (got #{v.inspect})"
        end

        def self.degree_pitch(d, scale)
          case d
          when nil then nil
          when Integer then scale[d].then { |n| n.is_a?(MB::Sound::Note) ? n.number : n }
          when Array then d.map { |x| degree_pitch(x, scale) }
          else raise ArgumentError, "Scale degrees are Integers from 0, Arrays for chords, or nil for rests (got #{d.inspect})"
          end
        end
      end

      class Clip
        # This clip's rhythm (a Rhythm: hits with lengths, velocities,
        # accents, and slides; pitches left out), to pour other pitches in:
        # `bass.rhythm.notes(C1, F1, A1, G1)`.
        def rhythm
          Rhythm.from_clip(self)
        end
      end
    end
  end
end

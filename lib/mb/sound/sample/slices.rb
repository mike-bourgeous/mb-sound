module MB
  module Sound
    class Sample
      # Slices of a Sample's region (Sample#slices): views of the same
      # audio, numbered in play order, with optional names for single slices
      # or runs of them.  A slice is a Sample (`brk[3].rev.transpose(2)`).
      #
      #     brk = rec.slices(16)
      #     brk[3]                         # the fourth sixteenth
      #     brk[4..7]                      # four joined into one
      #     brk = brk.name(k: 0..1, h: 2..3, s: 4..5, sk: 4..7, g: 7)
      #     brk[:sk]
      #     inst = brk.keymap(from: C2)    # one key per slice (Sampler::Instrument)
      #     amen = brk.chop(:k, T, :h, :g, [:s, 2], brk[:s].rev, R)   # a Clip
      #     bg :breaks, amen.sampler(brk)
      #     brk.keymap(from: C1, split: C4)  # slices below C4, the last one played chromatically above
      #
      # Keys (#keymap): from +from+ (C2), every slice in order, then every
      # named run that isn't a single slice, then the same again reversed.
      # Chop clips play those keys with a pitch mark on every hit
      # (Seq::Step#pitch), so slice and pitch stay separate:
      # `amen.transpose(2)` moves the marks (every hit a tone up), not the
      # keys.
      class Slices
        # Each slice's fade-out (seconds), so cuts don't click.
        DEFAULT_FADE = 0.002

        attr_reader :sample, :bounds, :names, :fade, :lineage

        # Slices of +sample+ (see Sample#slices).
        def self.build(sample, count, at: nil, fade: DEFAULT_FADE, **onsets)
          cuts =
            if count == :onsets || count == :transients
              p = sample.onsets(**onsets)
              p = [0] + p unless p.first == 0
              p + [sample.length]
            elsif count.is_a?(Integer)
              raise ArgumentError, "Slice counts are positive (got #{count})" unless count > 0
              raise ArgumentError, 'Give a slice count or at:, not both' if at
              (0..count).map { |i| (i * sample.length / count.to_r).round }
            elsif at
              p = Array(at).map { |x| sample.position(x).round }.sort.uniq
              raise ArgumentError, 'Slice points must be inside the sample' unless p.all? { |x| x >= 0 && x < sample.length }
              p + [sample.length]
            else
              raise ArgumentError, 'Give a slice count (slices(16)), points (slices(at: [...])), or :onsets'
            end
          raise ArgumentError, "Unknown slice options #{onsets.keys.inspect} (only with :onsets)" unless onsets.empty? || count == :onsets || count == :transients

          args = count ? [count] : []
          kwargs = { at: at, **onsets }.compact
          kwargs[:fade] = fade unless fade == DEFAULT_FADE
          rel = cuts.each_cons(2).reject { |a, b| b <= a }
          new(sample, rel, fade: sample.position(fade).to_f, lineage: [sample, :slices, args, kwargs])
        end

        # +bounds+ are [a, b] pairs relative to the region start in play
        # order.
        def initialize(sample, bounds, names: {}, fade: 0.0, lineage: nil)
          @sample = sample
          @bounds = bounds.map { |a, b| [Integer(a), Integer(b)].freeze }.freeze
          raise ArgumentError, 'Slices need at least one slice' if @bounds.empty?
          @names = names.dup.freeze
          @fade = fade
          @lineage = lineage
        end

        def length
          @bounds.length
        end
        alias size length
        alias count length

        # Slice +i+ (an Integer, negative from the end), a run of slices
        # joined (a Range of indices), or a named slice or run (a Symbol;
        # see #name).
        def [](i)
          case i
          when Symbol
            v = @names.fetch(i) { raise ArgumentError, "No slice named #{i.inspect} (#{@names.keys.map(&:inspect).join(', ')})" }
            slice_at(v, [i])
          else
            slice_at(i, [i])
          end
        end

        # Slices with names for slices (Integers) or runs (Ranges), merged
        # with any it has: `brk.name(k: 0..1, s: 4..5, g: 7)`.
        def name(**names)
          names.each do |k, v|
            ok = v.is_a?(Integer) ? !@bounds[v].nil? : v.is_a?(Range) && !@bounds[v].nil? && !@bounds[v].empty?
            raise ArgumentError, "Slice name #{k.inspect} must be a slice index or Range of indices (got #{v.inspect})" unless ok
          end
          Slices.new(@sample, @bounds, names: @names.merge(names), fade: @fade, lineage: [self, :name, [], names])
        end

        # Every slice in order (Samples).
        def to_a
          Array.new(length) { |i| self[i] }
        end

        def each(&block)
          to_a.each(&block)
        end

        def first
          self[0]
        end

        def last
          self[-1]
        end

        # The slice start positions (source samples from the region start).
        def starts
          @bounds.map(&:first)
        end

        # The absolute [start, stop] in the audio of the slice or run +i+
        # (Integer or Range).
        def absolute(i)
          rel = run(i)
          a, b = rel
          if @sample.reversed?
            [@sample.stop - b, @sample.stop - a]
          else
            [@sample.start + a, @sample.start + b]
          end
        end

        # The slices on keys (a Sampler::Instrument), +spread+ keys each
        # from +from+ (a Note or number; C2): every slice in order, then
        # every named run that isn't a single slice, then all of those
        # reversed (#chop's keys; keys past 127 or from +split+ up are left
        # out).  With +spread+ 1 each key plays its slice at its own pitch;
        # wider zones track the keys from the zone's first.  +split+ (a key)
        # makes a split keyboard: from it up, the last slice played below
        # plays chromatically (the split key at its own pitch).  +region+
        # options go to each region (see Sampler::Instrument#region).
        def keymap(from: 36, spread: 1, split: nil, **region)
          from = Sample.note_number(from).round
          spread = Integer(spread)
          raise ArgumentError, "Spread is a positive number of keys (got #{spread})" unless spread > 0
          top = split.nil? ? 128 : Sample.note_number(split).round
          entries = chop_entries
          if from + entries.length * spread > top
            raise ArgumentError, "#{entries.length} slices and runs of #{spread} key#{'s' if spread != 1} from #{from} don't fit below #{top} (start lower, or use fewer slices)"
          end
          kw = { from: from }
          kw[:spread] = spread if spread != 1
          kw[:split] = split if split
          slices = self
          Sampler::Instrument.new(split: split, lineage: [self, :keymap, [], kw.merge(region)]) { |inst|
            [false, true].each_with_index do |rev, bank|
              entries.each_with_index do |(arg, _), i|
                k = from + (bank * entries.length + i) * spread
                break if k + spread > top
                s = slices[arg]
                inst.region(rev ? s.rev : s, keys: k..(k + spread - 1), root: k, keytrack: spread > 1 ? 1 : 0, **region)
              end
            end
          }
        end

        # The instrument chop clips play (#keymap from C2).
        def instrument
          @instrument ||= keymap
        end

        # Plays as a synth voice (see Sampler::Instrument#play), e.g. in
        # `clip.sampler(brk)` or `synth(midi, voices: 1) { |v| brk.play(v) }`.
        def play(source = nil, **options)
          instrument.play(source, **options)
        end

        # A synth playing +source+ (MIDI; a chop clip) on #instrument (see
        # Sampler::Instrument#sampler).
        def sampler(source, **options, &block)
          instrument.sampler(source, **options, &block)
        end

        # A chop pattern (a Clip) in steps of +per+ (1/16 of a whole note by
        # default): each step a slice (an Integer index or a Symbol name),
        # [slice, semitones] (or [slice, semitones, vel: v]), a slice Sample
        # from these slices (`brk[:s].rev.transpose(2)`), Tie (T) to hold
        # the last hit, or Rest (R) / nil for silence.  Each hit is its
        # slice's key in #keymap (from +from+, +spread+ keys apart; C2 and 1
        # for #instrument) with a pitch mark of its semitones
        # (Seq::Step#pitch), so `clip.transpose(n)` pitches hits without
        # moving slices, and played live the keys trigger the same slices.
        #
        #     brk.chop(:k, T, :h, :g, [:s, 2], brk[:s].rev, R, :kk)
        def chop(*steps, per: 1/16r, from: 36, spread: 1)
          from = Sample.note_number(from).round
          list = chop_list
          values = steps.map { |s| chop_step(s, list, from, Integer(spread)) }
          MB::Sound.seq(*values).len(per)
        end

        # The chop regions' bounds: every slice, then every named run that
        # isn't a single slice (absolute [start, stop] pairs).
        def chop_list
          chop_entries.map(&:last)
        end

        def to_s
          n = @names.empty? ? '' : " (#{@names.keys.join(', ')})"
          "#{length} slices of #{@sample}#{n}"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        private

        # [a, b] relative bounds for an index or Range of indices.
        def run(i)
          case i
          when Integer
            @bounds.fetch(i) { raise IndexError, "Slice #{i} is outside 0...#{length}" }
          when Range
            r = @bounds[i]
            raise IndexError, "Slices #{i} are outside 0...#{length}" if r.nil? || r.empty?
            [r.first[0], r.last[1]]
          else
            raise ArgumentError, "Slices are indexed by Integers, Ranges, or names (got #{i.inspect})"
          end
        end

        def slice_at(i, args)
          a, b = absolute(i)
          @sample.with(start: a, stop: b, loop: nil, loop_mode: :one_shot, fade_out: @fade, lineage: [self, :[], args, {}].freeze)
        end

        # [index or name, absolute bounds] for every slice and every named
        # run that isn't a single slice, in key order.
        def chop_entries
          list = Array.new(length) { |i| [i, absolute(i)] }
          @names.each { |name, v| list << [name, absolute(v)] unless list.any? { |_, b| b == absolute(v) } }
          list
        end

        # The chop key of entry +idx+ (reversed in the second bank).
        def chop_key(idx, rev, count, from, spread)
          k = from + ((rev ? count : 0) + idx) * spread
          raise ArgumentError, "Chop key #{k} for #{rev ? 'reversed ' : ''}slice entry #{idx} is past 127 (chop from a lower key, or use fewer slices)" if k > 127
          k
        end

        def chop_step(s, list, from, spread)
          case s
          when nil, :rest then nil
          when Symbol, Integer then chop_value(s, 0, nil, list, from, spread)
          when Array
            raise ArgumentError, "A chop step Array is [slice, semitones] (got #{s.inspect})" unless (2..3).cover?(s.length)
            opts = s[2] || {}
            chop_value(s[0], s[1], opts[:vel] || opts[:velocity], list, from, spread)
          when Sample
            idx = list.index([s.start, s.stop])
            raise ArgumentError, "#{s} isn't one of these slices or named runs" unless idx
            key = chop_key(idx, s.reversed? != @sample.reversed?, list.length, from, spread)
            Sequence::Seq.step(key).pitch(s.tune - @sample.tune)
          else
            s # Tie, Rest, Steps
          end
        end

        def chop_value(slice, semitones, vel, list, from, spread)
          idx = slice.is_a?(Symbol) ? list.index(absolute(@names.fetch(slice) { raise ArgumentError, "No slice named #{slice.inspect}" })) : nil
          idx ||= Integer(slice) % length if slice.is_a?(Integer)
          raise ArgumentError, "Unknown chop step #{slice.inspect}" unless idx
          step = Sequence::Seq.step(chop_key(idx, false, list.length, from, spread)).pitch(semitones)
          vel ? Sequence::Seq::Step.new(**step.to_h.merge(velocity: vel.to_f)) : step
        end
      end
    end
  end
end

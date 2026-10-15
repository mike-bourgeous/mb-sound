require 'weakref'

module MB
  module Sound
    # A sound to play in a sampler (see design/notes/sampler.md): audio in
    # memory (one Numo::SFloat per channel at #sample_rate) with a #root
    # note, an optional loop, and the region of the audio it plays.  Samples
    # are values: every method returns a new Sample, and the views (#slices,
    # #at, #rev, #trim, #looped, #fade, #gain, #transpose) share the audio
    # and its band-limited playback tables, so cutting a break into slices
    # copies nothing.  Edits that change the sound (#bits, #lofi, #stretch,
    # #mono) make new audio from the region.
    #
    # Positions and lengths: Integers are samples, other numbers seconds,
    # and Lengths (`250.ms`, `96.samples`) or Durations (`7.n16`, counted at
    # the sample's #bpm when it has one, e.g. from #bounce, else the session
    # tempo) work too.
    #
    #     kick = Sample['sounds/kick.flac']                   # a file (root C4)
    #     pno  = Sample['piano_c4.flac', root: C4, loop: 0.5..1.2]
    #     rec  = bounce(2.bars, bpm: 138.75) { tr808(grid(16, kick: 'X...x...', snare: '....X...')) }
    #     brk  = rec.slices(16)                                # 16 equal slices (a Sample::Slices)
    #     rec.at(7.n16)                                        # play from the 8th sixteenth (tracker 9xx)
    #     rec.rev.bits(12)                                     # backwards, 12 bits
    #     synth(midi) { |v| pno.play(v) * v.env(0.002, 0.3, 0.8, 0.4) }
    class Sample
      # Loop modes: :one_shot plays to the end whatever the gate does (and
      # keeps a synth voice busy until then), :no_loop plays to the end or
      # until the voice's envelope releases, :forward loops while it plays,
      # :ping_pong loops back and forth, :release loops while the note is
      # held and then plays on to the end.
      LOOP_MODES = %i[no_loop one_shot forward ping_pong release].freeze

      # The audio data shared by a Sample and its views: the channels and the
      # playback tables built from them.
      class Audio
        attr_reader :channels, :sample_rate

        def initialize(channels, sample_rate)
          @channels = channels.map { |c| Numo::SFloat.cast(c).freeze }.freeze
          raise ArgumentError, 'A sample needs at least one channel' if @channels.empty?
          raise ArgumentError, 'Sample channels must be 1D' unless @channels.all? { |c| c.ndim == 1 }
          raise ArgumentError, 'Sample channels must be the same length' unless @channels.map(&:length).uniq.length == 1
          raise ArgumentError, 'A sample needs at least one sample of audio' if @channels[0].length < 1

          @sample_rate = sample_rate.to_f
          @tables = {}
          @edits = {}
          @mutex = Mutex.new
        end

        # The Sample made by an edit (see Sample#edit) of this audio named
        # by +key+, made by the block the first time (so the same edit of
        # the same sample, e.g. each `Sample["x.flac"].bits(12)` a graph
        # document prints, is one Sample sharing its playback tables).
        def edit(key)
          @mutex.synchronize { @edits[key] } || yield.tap { |s| @mutex.synchronize { @edits[key] ||= s } }
        end

        def length
          @channels[0].length
        end

        # The sample-mode Wavetable (no loop; the sampler loops) for channel
        # +c+ with level spacing +mips+, built on first use and kept.
        def table(c, mips = :default)
          key = [c % @channels.length, mips]
          @mutex.synchronize {
            @tables[key] ||= Wavetable.from_samples(
              @channels[key[0]], mode: :sample, root: 261.6255653005986, mips: mips, sample_rate: @sample_rate,
              name: 'sample'
            )
          }
        end
      end

      class << self
        # A Sample from +source+: a Sample (itself, or with +options+
        # changed), a String or Pathname (a sound file, see .from_file), a
        # Numo::NArray (1D: one channel; 2D: a row per channel), an Array of
        # NArrays (channels) or of numbers, or a sample-mode Wavetable.
        def [](source, **options)
          case source
          when Sample then options.empty? ? source : source.with(**options)
          when String, Pathname then from_file(source, **options)
          when Wavetable then from_wavetable(source, **options)
          else new(source, **options)
          end
        end

        # Reads a sound file (any format ffmpeg reads, resampled to 48 kHz).
        # Files saved by #save keep their settings (tags); +options+
        # override them.  In graph documents file names are relative to the
        # document (GraphIO::FileGuard).
        def from_file(path, **options)
          path = path.to_s
          key = cache_key(path, options)
          cached = key && @cache&.[](key)
          if cached
            begin
              return cached.__getobj__ if cached.weakref_alive?
            rescue WeakRef::RefError
              nil
            end
          end
          from_file_uncached(path, **options).tap { |s| (@cache ||= {})[key] = WeakRef.new(s) if key }
        end

        # A key for the file cache (the same file read again with the same
        # options is the same Sample, sharing its playback tables), or nil
        # for a file that can't be checked.
        def cache_key(path, options)
          real = defined?(GraphIO::FileGuard) ? GraphIO::FileGuard.resolve(path, 'reading a sample') : path
          st = File.stat(real.to_s)
          [File.expand_path(real.to_s), st.mtime.to_r, st.size, options.to_a]
        rescue SystemCallError
          nil
        end

        def from_file_uncached(path, **options)
          # (graph documents: the file inside the document's directory)
          real = defined?(GraphIO::FileGuard) ? GraphIO::FileGuard.resolve(path, 'reading a sample') : path
          tags = {}
          channels = MB::Sound.read(path, metadata_out: tags)
          info = saved_tags(tags)
          scale = info.delete(:scale)
          channels = channels.map { |c| c * scale } if scale
          new(channels, name: File.basename(path), file: options.empty? ? File.expand_path(real.to_s) : nil, **info.merge(options))
        end

        # A Sample of a sample-mode Wavetable's sound, root, and loop.
        def from_wavetable(table, **options)
          raise ArgumentError, 'Only sample-mode wavetables hold samples' unless table.mode == :sample
          root = MB::Sound.tuning.number_of(table.root)
          new(table.frames, root: root, loop: table.loop, sample_rate: table.sample_rate, name: table.name, **options)
        end

        # A level spacing (see #mips) from its tag.
        def saved_mips(text)
          case text
          when Numeric then text.to_f
          when 'false' then false
          when /\A[0-9.]+\z/ then Float(text)
          else text.to_sym
          end
        end

        # The settings read back from tags written by #save.
        def saved_tags(tags)
          t = tags.each_with_object({}) { |(k, v), h|
            k = k.to_s.downcase
            h[k.delete_prefix(TAG_PREFIX).to_sym] = v if k.start_with?(TAG_PREFIX)
          }
          return {} if t.empty?

          out = {}
          out[:root] = Float(t[:root]) if t[:root]
          out[:loop] = [Float(t[:loop_start]), Float(t[:loop_end])] if t[:loop_start] && t[:loop_end] # absolute
          out[:loop_mode] = t[:loop_mode].to_sym if t[:loop_mode]
          out[:start] = Integer(t[:start]) if t[:start]
          out[:stop] = Integer(t[:stop]) if t[:stop]
          out[:reverse] = t[:reverse] == 'true' if t[:reverse]
          out[:fade_in] = Float(t[:fade_in]) if t[:fade_in]
          out[:fade_out] = Float(t[:fade_out]) if t[:fade_out]
          out[:tune] = Float(t[:tune]) if t[:tune]
          out[:level] = Float(t[:level]) if t[:level]
          out[:bpm] = Float(t[:bpm]) if t[:bpm]
          out[:interpolation] = t[:interpolation].to_sym if t[:interpolation]
          out[:mips] = saved_mips(t[:mips]) if t[:mips]
          out[:scale] = Float(t[:scale]) if t[:scale]
          out
        end
      end

      # Methods that make new audio (the others are views of the same
      # audio); bundles save their results as assets.
      EDITS = %i[bits lofi stretch mono].freeze

      # The prefix of the tags #save writes.
      TAG_PREFIX = 'mb_sample_'

      # The audio this sample plays a region of (a Sample::Audio).
      attr_reader :audio

      # The region of the audio, in source samples (#start inclusive, #stop
      # exclusive).
      attr_reader :start, :stop

      # The note number (Float) at which the sample plays at its own speed.
      attr_reader :root

      # The loop as [start, end] source samples (end exclusive), or nil.
      attr_reader :loop_points

      # See LOOP_MODES.
      attr_reader :loop_mode

      # Fade lengths at the region's start and end (source samples), applied
      # while playing (slices fade out over 2 ms so cuts don't click).
      attr_reader :fade_in, :fade_out

      # Semitones added to the pitch, and the linear gain.
      attr_reader :tune, :level

      # The tempo the sample was recorded at (BPM; #bounce sets it), for
      # Durations; nil if unknown.
      attr_reader :bpm

      # A name for listings.
      attr_reader :name

      # How voices read this sample unless told otherwise (see #read_as):
      # an interpolation (Wavetable::INTERPOLATIONS; :none is the classic
      # drop-sample read) and a level spacing (Wavetable mips; false for no
      # band-limited levels), each nil for the voice's own (:optimal and
      # band-limited).  The lofi presets read :none without levels.
      attr_reader :interpolation, :mips

      # Named read styles for #read_as: the classic drop-sample read with no
      # band-limited levels (aliasing as it pitches up, like the hardware),
      # or the voice's own clean read.
      READ_STYLES = {
        drop: { interpolation: :none, mips: false }.freeze,
        clean: { interpolation: nil, mips: nil }.freeze,
      }.freeze

      # How this sample was made from another: [parent, method, args,
      # kwargs], or nil for a sample made from audio.
      attr_reader :lineage

      # Creates a Sample from +data+ (see .[]) at +sample_rate+ (48 kHz by
      # default).  +root+ is a Note, note number, or Pitch (C4 by default);
      # +loop+ a Range of positions (see the class description) or nil;
      # +loop_mode+ one of LOOP_MODES (:forward with a loop, else
      # :one_shot).
      def initialize(data, root: 60, loop: nil, loop_mode: nil, start: nil, stop: nil, reverse: false, fade_in: 0, fade_out: 0, tune: 0, level: 1.0,
                     bpm: nil, name: nil, interpolation: nil, mips: nil, sample_rate: 48000, audio: nil, lineage: nil, file: nil)
        @audio = audio || Audio.new(Sample.channels_of(data), sample_rate)
        @start = Integer(start || 0)
        @stop = Integer(stop || @audio.length)
        unless @start >= 0 && @stop <= @audio.length && @stop > @start
          raise ArgumentError, "A sample's region must lie inside its audio and not be empty (got #{@start}...#{@stop} of #{@audio.length})"
        end

        @root = Sample.note_number(root)
        @bpm = bpm&.to_f
        @loop_points = loop.nil? ? nil : Sample.loop_points(loop, self)
        @loop_mode = (loop_mode || (@loop_points ? :forward : :one_shot)).to_sym
        raise ArgumentError, "Unknown loop mode #{@loop_mode.inspect} (#{LOOP_MODES.join(', ')})" unless LOOP_MODES.include?(@loop_mode)
        if [:forward, :ping_pong, :release].include?(@loop_mode) && @loop_points.nil?
          raise ArgumentError, "Loop mode #{@loop_mode.inspect} needs a loop (looped(range, mode: #{@loop_mode.inspect}))"
        end

        @reversed = !!reverse
        @fade_in = fade_in.to_f
        @fade_out = fade_out.to_f
        @tune = tune.to_f
        @level = level.to_f
        @name = name
        @interpolation = interpolation&.to_sym
        if @interpolation && !Wavetable::INTERPOLATIONS.key?(@interpolation)
          raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (#{Wavetable::INTERPOLATIONS.keys.join(', ')}, or nil for the voice's)"
        end
        @mips = mips.is_a?(String) ? mips.to_sym : mips
        @lineage = lineage
        @file = file
        freeze
      end

      # The channels of +data+ as an Array of 1D arrays.
      def self.channels_of(data)
        case data
        when Numo::NArray
          case data.ndim
          when 1 then [data]
          when 2 then Array.new(data.shape[0]) { |c| data[c, true] }
          else raise ArgumentError, 'Sample data must be 1D (mono) or 2D (a row per channel)'
          end
        when Array
          if data.all? { |d| d.is_a?(Numo::NArray) }
            data
          elsif data.all?(Numeric)
            [Numo::SFloat.cast(data)]
          else
            raise ArgumentError, 'Give sample data as an NArray, an Array of NArrays (channels), or an Array of numbers'
          end
        else
          raise ArgumentError, "Cannot make a sample from #{data.class} (give a file name, NArray, Array, or Wavetable)"
        end
      end

      # The note number of +root+ (a Note, Pitch, or number).
      def self.note_number(root)
        case root
        when Note then root.detune == 0 ? root.number.to_f : root.detuned_number.to_f
        when Pitch then MB::Sound.tuning.number_of(root.frequency).to_f
        when Numeric then root.to_f
        else raise ArgumentError, "A sample's root is a Note, Pitch, or note number (got #{root.inspect})"
        end
      end

      # Loop points [start, end] (absolute source samples) for +range+
      # (positions relative to the region of +sample+; Integers samples,
      # Floats seconds, Lengths) or an Array of absolute points.
      def self.loop_points(range, sample)
        return range.map(&:to_f).freeze if range.is_a?(Array) && range.length == 2
        raise ArgumentError, "A loop is a Range of positions (got #{range.inspect})" unless range.is_a?(Range)

        a = range.begin.nil? ? sample.start.to_f : sample.start + sample.position(range.begin)
        b = range.end.nil? ? sample.stop.to_f : sample.start + sample.position(range.end) + (range.exclude_end? || range.end.nil? ? 0 : 1)
        raise ArgumentError, "The loop must be inside the sample and not empty (got #{range.inspect})" unless a >= sample.start && b <= sample.stop && b > a
        [a.to_f, b.to_f].freeze
      end

      # +x+ (an Integer of samples, other numbers seconds, a Length, or a
      # Duration at #bpm) as a number of source samples.
      def position(x)
        case x
        when Integer then x
        when Numeric then x * sample_rate
        when Length then Length.samples(x, sample_rate: sample_rate, transport: transport)
        else raise ArgumentError, "Expected a position (samples as an Integer, seconds, a Length, or a Duration; got #{x.inspect})"
        end
      end

      # The Transport Durations are counted at: the sample's #bpm, else the
      # session's.
      def transport
        @bpm ? Sequence::Transport.new(bpm: @bpm) : Sequence.transport
      end

      def sample_rate
        @audio.sample_rate
      end

      # The region's length in samples.
      def length
        @stop - @start
      end
      alias size length

      # The region's length in seconds.
      def seconds
        length / sample_rate
      end
      alias duration seconds

      def channel_count
        @audio.channels.length
      end

      def mono?
        channel_count == 1
      end

      # True if it plays backwards.
      def reversed?
        @reversed
      end

      # True if it has loop points.
      def looped?
        !@loop_points.nil?
      end

      # True if a synth voice stays busy until the sample ends (see
      # LOOP_MODES).
      def one_shot?
        @loop_mode == :one_shot
      end

      # A copy with +changes+ (any of #initialize's keywords: root, loop,
      # loop_mode, start, stop, reverse, fade_in, fade_out, tune, level,
      # bpm, name, interpolation, mips) sharing the audio.
      def with(**changes)
        changes = { lineage: [self, :with, [], changes.dup].freeze, **changes } unless changes.key?(:lineage)
        mode = @loop_mode
        if changes.key?(:loop) && !changes.key?(:loop_mode)
          looping = %i[forward ping_pong release]
          if changes[:loop].nil?
            mode = :one_shot if looping.include?(mode)
          elsif !looping.include?(mode)
            mode = :forward
          end
        end
        kw = {
          root: @root, loop: @loop_points, loop_mode: mode, start: @start, stop: @stop,
          reverse: @reversed, fade_in: @fade_in, fade_out: @fade_out, tune: @tune, level: @level, bpm: @bpm, name: @name,
          interpolation: @interpolation, mips: @mips, audio: @audio, lineage: @lineage,
        }
        Sample.new(nil, **kw.merge(changes))
      end

      # The region's audio for channel +c+ in play order (reversed if
      # #reversed?), scaled by #level, as a new SFloat.
      def data(c = 0)
        d = @audio.channels[c % channel_count][@start...@stop]
        d = d.reverse if @reversed
        d = d * @level if @level != 1
        d.dup
      end

      # The region's audio as an Array of SFloats, one per channel (see
      # #data).
      def to_a
        Array.new(channel_count) { |c| data(c) }
      end

      # The peak level of the region (all channels, after #level).
      def peak
        to_a.map { |d| d.abs.max.to_f }.max
      end

      # The part of the region from +range+'s begin to its end (positions
      # relative to the region start; see the class description).  Also
      # `sample[a...b]` with Integer samples.
      def trim(range)
        raise ArgumentError, "Trim takes a Range of positions (got #{range.inspect})" unless range.is_a?(Range)
        a = range.begin.nil? ? 0 : position(range.begin).round
        b = range.end.nil? ? length : position(range.end).round + (range.exclude_end? || range.end.nil? ? 0 : 1)
        a = a.clamp(0, length)
        b = b.clamp(0, length)
        raise ArgumentError, "The trimmed sample would be empty (#{range.inspect} of #{length} samples)" unless b > a
        if @reversed
          a, b = length - b, length - a
        end
        view(:trim, [range], start: @start + a, stop: @start + b, loop: clip_loop(@start + a, @start + b))
      end

      # Integer ranges trim (see #trim).
      def [](range)
        trim(range)
      end

      # The sample starting +offset+ into its region (a tracker's 9xx sample
      # offset), e.g. `rec.at(7.n16)`.
      def at(offset)
        o = position(offset).round
        raise ArgumentError, "The offset #{offset.inspect} is past the end of the sample" unless o >= 0 && o < length
        r = @reversed ? (@start...(@stop - o)) : ((@start + o)...@stop)
        view(:at, [offset], start: r.begin, stop: r.end, loop: clip_loop(r.begin, r.end))
      end

      # The sample backwards.  Alias #rev.
      def reverse
        view(:reverse, [], reverse: !@reversed)
      end
      alias rev reverse

      # The sample looping over +range+ (relative positions; the whole
      # region if nil) in +mode+ (:forward, :ping_pong, or :release, which
      # loops while the note is held).
      def looped(range = nil, mode: :forward)
        mode = mode.to_sym
        raise ArgumentError, "Loop modes are :forward, :ping_pong, and :release (got #{mode.inspect})" unless [:forward, :ping_pong, :release].include?(mode)
        points = Sample.loop_points(range || (0...length), self)
        args = range ? [range] : []
        view(:looped, args, { mode: mode }, loop: points, loop_mode: mode)
      end

      # The sample without a loop, playing to its end whatever the gate
      # does.
      def one_shot
        view(:one_shot, [], loop: nil, loop_mode: :one_shot)
      end

      # Fades over +in+ at the start and +out+ at the end of the region (in
      # play order), applied while playing.
      def fade(in: 0, out: 0)
        i = binding.local_variable_get(:in)
        view(:fade, [], { in: i, out: out }.reject { |_, v| v == 0 }, fade_in: position(i).to_f, fade_out: position(out).to_f)
      end

      # The sample +gain+ times louder (a number or Decibels: `gain(-6.db)`).
      def gain(gain)
        view(:gain, [gain], level: @level * gain.to_f)
      end

      # The sample scaled so its peak is +peak+ (1.0, or e.g. -1.db).
      def normalize(peak = 1.0)
        p = self.peak
        raise ArgumentError, 'Cannot normalize a silent sample' unless p > 0
        view(:normalize, peak == 1.0 ? [] : [peak], level: @level * peak.to_f / p)
      end

      # The sample +semitones+ higher (an Interval or a number; added to
      # #tune).
      def transpose(semitones)
        view(:transpose, [semitones], tune: @tune + Interval.semitones(semitones).to_f)
      end

      # Plays as a voice of a synth: see Sampler::Instrument#play (one
      # region over every key, tracking the keyboard from #root).
      #
      #     synth(midi) { |v| piano.play(v) * v.env(0.002, 0.3, 0.8, 0.4) }
      def play(source = nil, **options)
        to_instrument.play(source, **options)
      end

      # A Sampler::Instrument playing this sample on every key (keytrack 1),
      # or as given by +region+ options (see Sampler::Instrument#region).
      def to_instrument(**region)
        s = self
        Sampler::Instrument.new { |i| i.region(s, **region) }
      end

      # A graph node playing the sample once from its start (then ending),
      # e.g. `play kick.node` or `kick.node.reverb(:room)`.  Alias #to_node.
      def node(**options)
        to_instrument(keytrack: 0).node(**options)
      end
      alias to_node node

      # A granular cloud of this sample: a stereo Channels bundle of a
      # GraphNode::Grains (see design/notes/granular.md).  Every option is a
      # number or a node (knobs too), read per sample; each grain keeps the
      # values of its onset:
      # - density: grains per second (20; a Pitch, or a Duration for one
      #   grain per note length at the current tempo)
      # - jitter: 0 regular onsets (a buzz at the density) to 1 (default)
      #   Poisson onsets, the classic cloud
      # - size: grain length (100 ms; seconds, a Length, or a node)
      # - position: grain centers as a 0..1 fraction of the sample (or a
      #   Length); a number freezes (`position: 0.42`), a node scrubs
      # - scan: a playhead added to position, moving at +scan+ times the
      #   sample's own speed and wrapping (0.25 = a 4x granular stretch);
      #   1 when no position is given (plays through, looping), else 0
      # - spread: ± random position (0..1 of the sample, or a Length)
      # - pitch: semitones (an Interval or number), or an Array of them to
      #   pick from at random per grain (`[0, 12, 19]`); pitch_spread: ±
      #   random semitones
      # - pan_spread: 0 (center) to 1 (each grain anywhere left to right;
      #   0.5 by default)
      # - reverse: the chance a grain plays backwards (0..1, or true)
      # - window: :hann (default), :triangle, :tukey, :gauss, :blackman,
      #   :rect, :expodec (percussive), :rexpodec, a Proc of 0..1, or an
      #   Array (Granular::WINDOWS)
      # - normalize: (true) scale grains by 1 / sqrt(overlap) so dense
      #   clouds keep the sample's level
      # - max_grains: (32; 16 through Notes#grains) the most grains at once (more onsets are
      #   skipped: a fixed worst-case cost)
      # - seed: the grains' random seed (MB::Sound.next_seed by default)
      # - read: :clean or :drop (lofi drop-sample reads), or
      #   interpolation:/mips: as for #read_as; default the sample's own
      # - freq:, trigger: (Notes#grains sets them) key tracking against
      #   #root and note-ons restarting the playhead
      #
      #     bg :drone, bowl.grains(position: 0.42, size: 120.ms, density: 30, spread: 0.02)
      #     bg :rain, rain.grains(scan: 0.25, size: 60.ms, density: 80, pitch_spread: 3, reverse: 0.3)
      #     bg :spray, pad.grains(pitch: [0, 12, 19], window: :expodec, density: 60)
      def grains(read: nil, **options)
        s = read.nil? ? self : read_as(read)
        g = GraphNode::Grains.new(s, **options)
        GraphNode::Channels.new(g.outputs)
      end
      alias granular grains
      alias cloud grains

      # Slices of the region (a Sample::Slices): +count+ equal slices, or at
      # +at+ (an Array of positions from the region start), or at detected
      # transients with `slices(:onsets)` (see Sample::Onsets; +threshold+
      # and +min_gap+ tune the detector).  Each slice fades out over +fade+
      # (2 ms) so cuts don't click.
      #
      #     brk = rec.slices(16)
      #     brk = rec.slices(at: [0, 2.n16, 7.n16, 12.n16])
      #     brk = rec.slices(:onsets)
      def slices(count = nil, at: nil, fade: Slices::DEFAULT_FADE, **onsets)
        Slices.build(self, count, at: at, fade: fade, **onsets)
      end
      alias slice slices
      alias chops slices

      # The transient times (source samples from the region start) found by
      # Sample::Onsets.
      def onsets(**options)
        Onsets.detect(self, **options)
      end

      # The sample reduced to +bits+ (rounded to 2^(bits-1) steps).
      def bits(bits)
        edit(:bits, [bits]) { |d| Lofi.bits(d, bits) }
      end

      # The sample through a classic sampler's converters (see Sample::Lofi):
      # a preset (:s950, :sp1200, :mpc60) or +rate+ (Hz), +bits+, and an
      # output +filter+ (Hz, or nil).  Each preset also says how voices
      # read it (Lofi::PRESET_READS): :mpc60, the cleanest, reads clean;
      # :s950 and :sp1200 read drop-sample with no band-limited levels,
      # like the hardware (aliasing as notes pitch up; maintainer's Bench
      # verdicts, 2026-10-13).  +read+ (:clean, :drop, or a Hash as for
      # #read_as) says otherwise.
      #
      #     brk = rec.lofi(:mpc60).slices(16)              # 12-bit grit, read clean
      #     brk = rec.lofi(:sp1200).slices(16)             # dirty: drop-sample reads
      #     pad = rec.lofi(:s950, read: :clean)            # the converter, read clean
      #     hat = rec.lofi(:mpc60, read: :drop)            # the MPC60 read like an S950
      def lofi(preset = nil, read: nil, **options)
        settings = Lofi.settings(preset, **options)
        args = preset ? [preset] : []
        style = read.nil? && preset ? Lofi::PRESET_READS.fetch(preset.to_sym) : read
        kwargs = read.nil? ? options : options.merge(read: read)
        edit(:lofi, args, kwargs, read: read_settings(style)) { |d| Lofi.process(d, sample_rate: sample_rate, **settings) }
      end

      # The same sample read by voices as +style+ says unless the voice is
      # told otherwise: :drop (interpolation :none, no band-limited levels:
      # the classic sampler read, aliasing as it pitches up) or :clean (the
      # voice's own read: :optimal, band-limited), with +interpolation+
      # (Wavetable::INTERPOLATIONS, or nil) and +mips+ (a level spacing,
      # false, or nil) changed.  A view (no new audio).
      #
      #     rec.lofi(:sp1200).read_as(:clean)            # the converter without the aliasing read
      #     kick.read_as(:drop)                          # a clean sample read like an S950
      #     pad.read_as(interpolation: :cubic, mips: false)
      def read_as(style = nil, **changes)
        bad = changes.keys - [:interpolation, :mips]
        raise ArgumentError, "read_as takes a style (#{READ_STYLES.keys.join(', ')}) and interpolation:/mips: (got #{bad.inspect})" unless bad.empty?
        view(:read_as, style.nil? ? [] : [style], changes, **read_settings(style).merge(changes))
      end

      # The sample stretched to +ratio+ times its length at the same pitch,
      # S950-style cyclic timestretch: cycles of about +cycle+ (25 ms)
      # taken from the input in step and repeated or skipped, each
      # crossfading into the next over +crossfade+ (3 ms; raised-cosine
      # fades, equal-gain where the two sides match and equal-power where
      # they don't, Lofi.crossfade_gains; 0 for hard cuts).  +fit+
      # (Lofi::FITS) :auto, the default, fits each cycle to the sound: a
      # whole number of its local periods (autocorrelation, followed from
      # cycle to cycle so the count doesn't jump), each splice where the
      # sound matches what would have followed (the S950's "cycle
      # fudging"), so tones keep their pitch and breaks get smaller seams.
      # :fixed is the plain cyclic stretch: cycles of exactly +cycle+, cut
      # anywhere (crossfaded like :auto's; `crossfade: 0` for the raw
      # splices); short cycles buzz at 1 / cycle (metallic), long ones
      # stutter, and tones whose period doesn't divide the cycle retune (a
      # 55 Hz bass at 2x with 30 ms cycles sounds about an octave low; see
      # Lofi::FITS).  Every channel cuts in the same places.
      #
      #
      # +mode+ :spectral (aliases :pv, :vocoder) is a phase vocoder with
      # identity phase locking (Laroche & Dolson): Hann windows of +window+
      # (4096 samples) with +overlap+ (4) frames per window, every channel
      # rotated by the phases of their mix (a steady stereo image), and
      # with +transients+ (true) each detected onset (Sample::Onsets)
      # landing at +ratio+ times its time with its attack unstretched (the
      # decay between hits drawn out) and the phases of its rising bins
      # reset, so attacks stay sharp and breaks keep their groove; best on
      # pads, chords, voices, basses (pitch is kept exactly), and breaks.
      # :paul (:paulstretch) is Paulstretch: windows of +window+ (0.25 s),
      # +overlap+ (4; Nasca Paul's original uses 2: half as many phase
      # changes per second, so each partial spreads over half the
      # bandwidth, less chorus), every phase random (from +seed+, 0 by
      # default, so the same stretch gives the same audio): glacial washes
      # at extreme ratios (8x to 1000x); +transients+ (false for :paul)
      # keeps the attack bins at onsets unrandomized.
      #
      # The two are one algorithm: +randomize+ (0..1; 0 for :spectral, 1
      # for :paul) adds up to ± randomize × π of random phase to every bin
      # each frame, from the locked vocoder (0) through a smeared, diffuse
      # vocoder to Paulstretch (1); the modes only choose the defaults
      # (window, randomize, transients).  +link+ (true) gives every channel
      # the same random phases (the image keeps its level panning); false
      # draws them per channel like the original Paulstretch (a wider,
      # decorrelated stereo image; a mono sample stays mono).  +shape+
      # (Spectral::SHAPES) is the window: :hann, or :paul, the original's
      # flatter (1 - x²)^1.25 (random phases smear partials less: a
      # Paulstretched sine measured 6.6 Hz wide at -6 dB instead of 10.3).
      #
      # Results longer than LONG_STRETCH (30 s) read with `mips: :octave`
      # unless this sample has its own mips (smaller playback tables for
      # long drones; voices' and grains' mips: still win).  Both are
      # offline (a new Sample, made once per audio and arguments; spectral
      # runs about 50x realtime per output channel).
      #
      #     pad.stretch(2, cycle: 30.ms)               # cycles fitted to the sound
      #     brk.stretch(2, cycle: 30.ms, fit: :fixed)  # the plain cyclic stretch (stutter, buzz)
      #     pad.stretch(8, mode: :spectral)            # phase vocoder
      #     pad.stretch(8, mode: :spectral, randomize: 1)     # Paulstretch-like phases in the vocoder's 4096-sample window
      #     bowl.stretch(100, mode: :paul, window: 0.5.seconds)  # an endless wash
      #     voice.stretch(8, mode: :paul, overlap: 2, shape: :paul, link: false)   # like Nasca Paul's original (voices)
      def stretch(ratio, mode: :cyclic, cycle: 25.ms, crossfade: CROSSFADE, fit: :auto, window: nil, overlap: Spectral::OVERLAP, transients: nil, seed: 0, randomize: nil, link: true, shape: :hann)
        mode = Spectral.mode_name(mode)
        return spectral_stretch(ratio, mode, window, overlap, transients, seed, randomize, link, shape) unless mode == :cyclic
        unless window.nil? && overlap == Spectral::OVERLAP && transients.nil? && seed == 0 && randomize.nil? && link == true && shape == :hann
          raise ArgumentError, 'window:, overlap:, shape:, transients:, seed:, randomize:, and link: are for mode: :spectral and :paul'
        end

        fit = Lofi.fit_name(fit)
        c = position(cycle).round
        x = position(crossfade).round
        kw = { cycle: cycle, crossfade: crossfade, fit: fit }.reject { |k, v| k == :cycle ? v == 25.ms : (k == :fit ? v == :auto : v == CROSSFADE) }
        guide = nil
        edit(:stretch, [ratio], kw, read: stretch_read(ratio)) { |d|
          guide ||= fit == :auto ? mono_mix : nil
          Lofi.stretch(d, ratio.to_f, c, x, fit: fit, guide: guide, sample_rate: sample_rate)
        }
      end

      # The cyclic stretch's default crossfade between cycles.
      CROSSFADE = 3.ms

      # Stretch results longer than this (seconds) read with :octave level
      # spacing unless the sample says otherwise (about 8x the audio for
      # the band-limited levels instead of about 14x: a 160 s Paulstretch
      # would take ~420 MB at the default spacing; maintainer, 2026-10-14).
      LONG_STRETCH = 30

      # The read settings for a stretch by +ratio+ (see LONG_STRETCH).
      def stretch_read(ratio)
        long = length * ratio.to_f / sample_rate > LONG_STRETCH
        { interpolation: @interpolation, mips: @mips.nil? && long ? :octave : @mips }
      end
      private :stretch_read

      # The :spectral and :paul stretches (see #stretch): one phase
      # vocoder whose +randomize+ goes from locked phases (0) to random
      # ones (1, Spectral.paul's magnitude-only frames when no onsets are
      # kept); the modes set the defaults.
      def spectral_stretch(ratio, mode, window, overlap, transients, seed, randomize, link, shape)
        paul = mode == :paul
        transients = !paul if transients.nil?
        randomize = paul ? 1 : 0 if randomize.nil?
        raise ArgumentError, "randomize: is 0..1 (got #{randomize.inspect})" unless randomize.is_a?(Numeric) && randomize >= 0 && randomize <= 1

        kw = { mode: mode }
        kw[:window] = window unless window.nil?
        kw[:overlap] = overlap unless overlap == Spectral::OVERLAP
        kw[:transients] = transients unless transients == !paul
        kw[:randomize] = randomize unless randomize == (paul ? 1 : 0)
        kw[:link] = link unless link == true
        kw[:shape] = shape unless shape == :hann
        Spectral.shaped_window(shape, 64) # (checks the name)
        kw[:seed] = seed unless seed == 0 || randomize == 0

        n = position(window.nil? ? (paul ? Spectral::PAUL_WINDOW : Spectral::WINDOW.samples) : window).round
        n += 1 if n.odd?
        onsets = transients ? (@reversed ? reverse : self).onsets : nil
        edit(:stretch, [ratio], kw, whole: true, read: stretch_read(ratio)) { |chans|
          if randomize >= 1 && onsets.nil?
            Spectral.paul(chans, ratio.to_f, window: n, overlap: overlap, seed: seed, link: link, shape: shape)
          else
            Spectral.vocoder(chans, ratio.to_f, window: n, overlap: overlap, onsets: onsets, randomize: randomize, seed: seed, link: link, shape: shape)
          end
        }
      end
      private :spectral_stretch

      # The channels mixed to one.
      def mono
        return self if mono?
        mix = to_a.sum / channel_count
        edit(:mono, [], {}, channels: [mix])
      end

      # Saves the whole audio and this sample's settings as tags (see
      # .from_file) to +path+ (FLAC by default).
      def save(path, overwrite: false)
        chans = @audio.channels
        peak = chans.map { |c| c.abs.max.to_f }.max
        scale = peak > 1 ? peak : nil
        chans = chans.map { |c| c / scale } if scale
        MB::Sound.write(path, chans, sample_rate: sample_rate, overwrite: overwrite, metadata: tags.merge(scale ? { "#{TAG_PREFIX}scale": scale } : {}))
        path
      end

      # The tags #save writes.
      def tags
        t = {
          root: @root, start: @start, stop: @stop, loop_mode: @loop_mode, reverse: @reversed, fade_in: @fade_in, fade_out: @fade_out,
          tune: @tune, level: @level, bpm: @bpm, interpolation: @interpolation, mips: @mips.nil? ? nil : @mips.to_s,
        }
        t.merge!(loop_start: @loop_points[0], loop_end: @loop_points[1]) if @loop_points
        t.compact.to_h { |k, v| [:"#{TAG_PREFIX}#{k}", v.is_a?(Numeric) || v.is_a?(String) ? v : v.to_s] }
      end

      # The file this sample was read from without options (graph
      # documents copy it into bundles), or nil.
      def file
        @file
      end

      # The sample this one was cut or edited from (following #lineage to
      # the start), or itself.
      def origin
        @lineage ? @lineage[0].origin : self
      end

      def to_s
        parts = ["#{format('%.3f', seconds)} s"]
        parts << "#{channel_count} ch" unless mono?
        parts << "root #{Sample.note_name(@root)}"
        parts << "loop #{@loop_mode}" if @loop_points
        parts << 'reversed' if @reversed
        parts << read_style_name if @interpolation || !@mips.nil?
        parts << "#{MB::M.sigfigs(@tune, 3)} st" if @tune != 0
        "#{@name || 'Sample'} (#{parts.join(', ')})"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      # A note name for note number +n+ (e.g. C4), or the number.
      def self.note_name(n)
        n == n.round ? Note.new(n.round).name : MB::M.sigfigs(n, 5).to_s
      rescue StandardError
        n.to_s
      end

      private

      # A view sharing the audio, remembering +method+ and +args+ for
      # printing.
      def view(method, args, kwargs = {}, **changes)
        with(lineage: [self, method, args, kwargs].freeze, **changes)
      end

      # A new sample from the region's audio in stored order, edited by the
      # block (called with each channel's SFloat, returning the new
      # channel), with the loop and settings kept (loop points scaled with
      # the length) and read as +read+ says (see #read_as).
      def edit(method, args, kwargs = {}, channels: nil, whole: false, read: { interpolation: @interpolation, mips: @mips }, &block)
        key = [@start, @stop, @root, @loop_points, @loop_mode, @reversed, @fade_in, @fade_out, @tune, @level, @bpm, @interpolation, @mips, method, args, kwargs]
        @audio.edit(key) { edit_uncached(method, args, kwargs, channels: channels, whole: whole, read: read, &block) }
      end

      def edit_uncached(method, args, kwargs, channels: nil, whole: false, read: { interpolation: @interpolation, mips: @mips })
        src = Array.new(channel_count) { |c| @audio.channels[c][@start...@stop].dup }
        out = channels || (whole ? yield(src).map { |d| Numo::SFloat.cast(d) } : src.map { |d| Numo::SFloat.cast(yield(d)) })
        len = out[0].length
        loop = nil
        if @loop_points
          k = len.to_f / length
          a = ((@loop_points[0] - @start) * k).floor
          b = ((@loop_points[1] - @start) * k).ceil.clamp(a + 1, len)
          loop = [a.to_f, b.to_f] if a >= 0 && a < len
        end
        Sample.new(
          out, root: @root, loop: loop, loop_mode: loop ? @loop_mode : (@loop_points ? :one_shot : @loop_mode), reverse: @reversed,
          fade_in: @fade_in, fade_out: @fade_out, tune: @tune, level: @level, bpm: @bpm, name: @name, sample_rate: sample_rate,
          interpolation: read[:interpolation], mips: read[:mips], lineage: [self, method, args, kwargs].freeze
        )
      end

      # The region's channels mixed (stored order, before #level), as a
      # DFloat.
      def mono_mix
        chans = Array.new(channel_count) { |c| Numo::DFloat.cast(@audio.channels[c][@start...@stop]) }
        chans.sum / channel_count
      end

      # The read settings ({ interpolation:, mips: }) of +style+ (a
      # READ_STYLES name, a Hash of them, or nil for this sample's own).
      def read_settings(style)
        case style
        when nil then { interpolation: @interpolation, mips: @mips }
        when Hash then { interpolation: @interpolation, mips: @mips }.merge(style.slice(:interpolation, :mips))
        else READ_STYLES.fetch(style.to_sym) { raise ArgumentError, "Unknown read style #{style.inspect} (#{READ_STYLES.keys.join(', ')})" }
        end
      end

      # :drop, :clean, or the settings, for #to_s.
      def read_style_name
        style = READ_STYLES.key({ interpolation: @interpolation, mips: @mips })
        style ? "#{style} read" : "read #{@interpolation || 'default'}, mips #{@mips.inspect}"
      end

      # The loop clipped to a new region (nil if it falls outside).
      def clip_loop(a, b)
        return nil unless @loop_points
        la = MB::M.max(@loop_points[0], a.to_f)
        lb = MB::M.min(@loop_points[1], b.to_f)
        lb > la ? [la, lb] : nil
      end
    end
  end
end

require_relative 'sample/slices'
require_relative 'sample/onsets'
require_relative 'sample/lofi'
require_relative 'sample/spectral'

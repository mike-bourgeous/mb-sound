module MB
  module Sound
    module Mastering
      # Reaching a mastering preset's loudness target in a render (the
      # maintainer's "renders measure, then set the gain exactly",
      # 2026-10-17).  PlaybackMethods#render runs the render block twice:
      #
      # 1. The first pass renders as usual (the trim at each preset's drive)
      #    while a Capture records the mix that leaves the Session (its tap)
      #    and, for every master chain with a targeted preset, the chain's
      #    input, its output, and its fade ramp on every span.
      # 2. .solve rebuilds those chains offline (same blocks, same random
      #    seeds) with other trims and runs them over their recorded inputs:
      #    the render's output with trim g is the recorded mix minus the
      #    chains' recorded outputs plus their outputs at g.  A few secant
      #    steps on the integrated loudness of that (BS.1770, from the
      #    render window's first frame) find the trim that reaches the
      #    target; presets without a limiter (:vinyl) then lower it until
      #    the true peak is under the ceiling.
      # 3. The second pass renders again (the block re-run with the root
      #    random generator put back) with that trim in every targeted
      #    preset.
      #
      # Every stage is a function of samples, never of buffer boundaries,
      # so the found trim and the file are the same at any buffer size.
      # Stems are the parts before the master chain, so the trim doesn't
      # change them.
      module Targeting
        # The most secant steps .solve takes (it usually needs 2-4).
        MAX_STEPS = 10

        # measure: :sections: the most rounds of per-section steps, how
        # close each section gets (LU), and the ramp between section trims
        # (whole notes: a quarter note).
        SECTION_STEPS = 6
        SECTION_TOLERANCE = 0.05
        SECTION_RAMP = Rational(1, 4)
        # The most a section's trim may sit over the loudest section's (dB):
        # with energy under 1, a quiet pass far under the drops (Tunnel
        # Vision's ring-out tail, 10 LU under) would otherwise come up by
        # 20 dB or more.
        SECTION_MAX_LIFT = 6.0

        # How close to the target .solve gets (LU).
        TOLERANCE = 0.01

        # The farthest the trim may move from the first pass's (dB).
        RANGE = 36.0

        class << self
          # The Result of the last targeted render (nil before one).
          attr_accessor :last
        end

        # What a render's first pass records (see Targeting).  Session#add
        # calls #saw with each graph; the second pass's Capture (+check:
        # true+) raises if the block gives it a graph the first pass
        # already played (it would continue from where the first pass left
        # it, not start again).
        class Capture
          # One master chain's record: the Session::Master::Chain, and per
          # span its +frames+ (session frame of the first sample), +inputs+,
          # +outputs+ (with its ramp applied, as added to the mix).
          # +built+ lists the chain's presets (Mastering::Built: each with
          # the Tap recording the signal entering its trim).
          ChainRecord = Struct.new(:chain, :frames, :inputs, :outputs, :ramps, :built) do
            def add(frame, input, data, ramp)
              frames << frame
              inputs << input.map { |d| d.dup }
              outputs << data.map { |d| ramp ? d * ramp : d.dup }
              ramps << ramp&.dup
            end
          end

          # The ChainRecords.
          attr_reader :chains

          # The Session's mix per buffer, as [frame, channels] pairs.
          attr_reader :mix

          def initialize(check: nil)
            @chains = []
            @mix = []
            @seen = {}.compare_by_identity
            @check = check
            @marks = nil
          end

          # The song form's section passes the first pass played, as
          # [session frame, label] (see MixReport::SectionMarks), for
          # measure: :sections.
          def sections
            @marks ? @marks.boundaries : []
          end

          # Notes section starts in the span at +frame+ of +count+ frames
          # from transport position +pos+ (Session#render_master_chain, for
          # chains with targeted presets).
          def note_sections(session, frame, count, pos)
            return if @check
            (@marks ||= MixReport::SectionMarks.new(session)).note(frame, count, pos: pos)
          end

          # A new ChainRecord for +chain+ (Session#build_master; nil in a
          # second pass).
          def chain(chain, built)
            return nil if @check # (the second pass only checks graphs)
            built.each { |b| b.tap&.recording = true }
            ChainRecord.new(chain, [], [], [], [], built).tap { |r| @chains << r }
          end

          # Records the mix leaving the Session at +frame+ (a tap).
          def add_mix(frame, data)
            return if data.empty? || data[0].nil? || data[0].empty? # (a buffer of no frames, e.g. at a seek)
            @mix << [frame, data.map(&:dup)]
          end

          # Notes the nodes of a graph given to Session#add (the second
          # pass checks them against the first's).
          def saw(nodes)
            nodes.each do |n|
              n.graph.each do |g|
                next unless (g.is_a?(GraphNode) || g.is_a?(GraphNode::MultiOutput)) && !g.frozen?
                if @check&.seen?(g)
                  raise ArgumentError, "A loudness-targeted render runs its block twice (see Mastering::Targeting), but the block played a graph built outside it (#{g.class.name.split('::').last}); build the graphs inside the block, or pass loudness: false"
                end
                @seen[g] = true
              end
            end
          end

          # True if the first pass played +node+.
          def seen?(node)
            @seen.key?(node)
          end

          # The ChainRecords of chains with targeted presets that ran.
          def targeted
            @chains.select { |c| !c.frames.empty? && c.chain.mastering&.any?(&:targeted?) }
          end

          # The targeted presets that ran (in the order their chains were
          # built).
          def presets
            targeted.flat_map { |c| c.chain.mastering.select(&:targeted?) }
          end
        end

        # The per-section trims of measure: :sections (see .solve): gains in
        # dB at session frames (+points+: [[frame, dB], ...], held before
        # the first and after the last, joined linearly in dB), so the
        # trim is a function of the frame alone and the same at any buffer
        # size.  Preset#apply multiplies the signal entering the trim by it
        # (#apply).  Section changes ramp over SECTION_RAMP toward the lower
        # trim first: a louder section's trim is reached by its first
        # frame, a quieter section's starts rising at its first frame, so
        # the loud material never plays at a quiet section's trim.
        class TrimCurve
          # [[session frame, dB], ...], frames ascending.
          attr_reader :points

          # While .solve replays a recorded chain: the session frame of the
          # span being run (nil in a render, which reads Session#frame).
          attr_accessor :frame_override

          def initialize(points)
            @points = points.map { |f, d| [Integer(f), Float(d)].freeze }.sort_by(&:first).freeze
            @frame_override = nil
          end

          # The trim (dB) at each of +count+ frames from session frame
          # +start+, as a Numo::DFloat.
          def db_at(start, count)
            out = Numo::DFloat.new(count).fill(@points[0][1])
            @points.each_cons(2) do |(f0, d0), (f1, d1)|
              a = [f0 - start, 0].max
              b = [f1 - start, count].min
              next if b <= a || a >= count
              if d0 == d1 || f1 == f0
                out[a...b] = d0
              else
                frames = Numo::DFloat.new(b - a).seq(a + start)
                out[a...b] = (frames - f0) * ((d1 - d0) / (f1 - f0)) + d0
              end
            end
            last_f, last_d = @points[-1]
            a = [last_f - start, 0].max
            out[a..] = last_d if a < count
            out
          end

          # Linear gains (Numo::SFloat) for +count+ frames from +start+.
          def gains(start, count)
            Numo::SFloat.cast(10.0**(db_at(start, count) / 20.0))
          end

          # Multiplies +mix+ (a node or bundle) by the curve, reading the
          # frame from +session+ (Session#frame, the span's first frame
          # while it renders) unless #frame_override is set.
          def apply(mix, session:)
            outs = mix.outputs
            nodes = outs.map { |o| Node.new(o, self, session) }
            nodes.length == 1 ? nodes[0] : GraphNode::Channels.new(nodes)
          end

          def inspect
            "#<#{self.class.name} #{@points.map { |f, d| format('%d:%+.2f', f, d) }.join(' ')}>"
          end

          # One channel through the curve (see TrimCurve#apply).
          class Node
            include GraphNode
            include GraphNode::SampleRateHelper

            def initialize(input, curve, session)
              @input = input.get_sampler
              @curve = curve
              @session = session
              @sample_rate = input.sample_rate.to_f
              @buf = nil
              @node_type_name = 'Section Trim'
            end

            def sample(count)
              data = @input.sample(count)
              return nil if data.nil?

              start = @curve.frame_override || @session.frame
              @buf = Numo::SFloat.zeros(data.length) if @buf.nil? || @buf.length != data.length
              @buf[0..] = data
              @buf.inplace * @curve.gains(start, data.length)
              @buf.not_inplace!
            end

            def sources
              { input: @input }
            end
          end
        end

        # A pass-through bundle at a preset's trim that records what enters
        # it (every buffer, while +recording+), so .solve can run the trim
        # and the steps after it again without the rest of the chain (which
        # may read knobs, buses, or players, and draw random seeds).
        class Tap < GraphNode::Channels
          # One output of a Tap.
          class Output
            include GraphNode
            include GraphNode::NodeOutput

            def initialize(tap:, index:, input:)
              @owner = tap
              @index = index
              @input = input
              @node_type_name = 'Mastering tap'
            end

            def sample(count)
              @owner.sample_internal(count, @index)
            end

            def sample_rate
              @owner.sample_rate
            end

            def sources
              { input: @input }
            end
          end

          # True while recording (set by Capture#chain).
          attr_accessor :recording

          # The recorded buffers, one Array of channels per buffer.
          attr_reader :buffers

          def initialize(inputs)
            @inputs = inputs.map(&:get_sampler)
            @recording = false
            @buffers = []
            @sampled = Array.new(@inputs.length, false)
            @data = nil
            super(@inputs.each_with_index.map { |input, idx| Output.new(tap: self, index: idx, input: input) })
          end

          def sample_rate
            @inputs[0].sample_rate
          end

          # Samples every input when output +index+ starts a new buffer.
          def sample_internal(count, index)
            if @sampled[index] || @data.nil?
              @sampled.fill(false)
              @data = @inputs.map { |i| i.sample(count) }
              @buffers << @data.map { |d| d&.dup } if @recording
            end
            @sampled[index] = true
            @data[index]
          end
        end

        # The outcome of .solve: the +preset+ name, the +trim+ (Decibels),
        # the +target+ (Loudness::Target) and +ceiling+ (Decibels), and the
        # render as predicted from the first pass: +integrated+ and
        # +short_term_max+ (LUFS), +range+ (LRA, LU), +true_peak+ (dBTP),
        # +side+ (dB, the side against the mid below +side_hz+; see
        # Genre.low_side_db), the first pass's loudness, the number of chain
        # runs, and +held+ (true when the ceiling, not the target, set the
        # trim).  +codec_peaks+ ({ codec => dBTP } of the written file, or
        # nil) is filled in by the render when measured.
        #
        # +measure+ is what the target measured (:integrated; :loudest:
        # +loudest+ is then the loudest +loudest_bars+-bar window's LUFS;
        # :bars: +loudest+ is then the level +percentile+ of the bars sit
        # at or under; see Mastering::MEASURES).  +drive+ (Decibels) is the trim the
        # first pass used (the preset's drive).
        #
        # :match (Mastering::Reference): +reference+, +tilt+ (the tilt EQ's
        # correction, dB per octave, nil unless measured), +tilt_in+ (the
        # mix's tilt at the trim), and +tilt_out+ (the render's).
        Result = Data.define(:preset, :trim, :target, :ceiling, :integrated, :short_term_max, :range, :true_peak, :side, :side_hz,
                             :first_pass, :runs, :held, :codec_peaks, :measure, :loudest, :loudest_bars, :drive, :percentile, :side_in,
                             :trims, :sections, :energy, :reference, :tilt, :tilt_in, :tilt_out) do
          def initialize(drive: nil, percentile: nil, side_in: nil, trims: nil, sections: nil, energy: nil, reference: nil, tilt: nil, tilt_in: nil, tilt_out: nil, **rest)
            super(drive: drive, percentile: percentile, side_in: side_in, trims: trims, sections: sections, energy: energy,
              reference: reference, tilt: tilt, tilt_in: tilt_in, tilt_out: tilt_out, **rest)
          end

          # The loudness the target was reached with (integrated, the
          # loudest window's, or the bars' percentile level).
          def measured
            measure == :integrated ? integrated : loudest
          end

          # Peak-to-loudness ratio (LU).
          def plr
            true_peak - integrated
          end

          # True if the loudness is within 0.5 LU of the target (or the
          # ceiling held it under) and the true peak is under the ceiling
          # (within 0.1 dB, the limiter's tolerance).
          def pass?
            (held || (measured - target.lufs).abs <= 0.5) && true_peak <= ceiling.db_value + 0.1
          end

          # The decoded peaks over -0.1 dBTP (players clip them), or {}.
          def codec_overs
            CodecPeaks.overs(codec_peaks, CODEC_LIMIT)
          end

          def to_s
            lines = []
            # The trim is the gain into the chain, where the limiters turn
            # most of it into peak control: say how it relates to the first
            # pass, so +23.6 dB for 3.5 LU more doesn't read as wrong
            # (ux-fix-1 item 22)
            first = drive ? format("the first pass's drive %+.2f dB gave %.2f LUFS", drive.db_value, first_pass) : format('first pass %.2f LUFS', first_pass)
            change = drive ? format('; %+.2f dB more trim for %+.2f LU (the chain compresses and limits)', trim.db_value - drive.db_value, measured - first_pass) : ''
            lines << format('mastering %s: %s (trim %+.2f dB into the chain; %s%s; %d chain runs)',
                            preset.inspect, pass? ? 'pass' : 'FAIL', trim.db_value, first, change, runs)
            target_text = case measure
                          when :loudest then format('loudest %d bars %.2f LUFS, target %.1f', loudest_bars, loudest, target.lufs)
                          when :bars then format('bars at the %s percentile %.2f LUFS, target %.1f', Mastering.ordinal((percentile * 100).round), loudest, target.lufs)
                          when :sections then format('loudest section %.2f LUFS, target %.1f, energy %.2f', loudest, target.lufs, energy)
                          else format('target %.1f', target.lufs)
                          end
            lines << format('  loudness %.2f LUFS (%s%s), short-term max %.1f, LRA %.1f LU, PLR %.1f LU',
                            integrated, target_text, held ? format(', held by the %.1f dBTP ceiling: no limiter', ceiling.db_value) : '',
                            short_term_max, range, plr)
            db_text = ->(v) { v ? (v.finite? ? format('%.1f dB', v) : '-inf dB') : 'n/a' }
            # The side in the mix before the chain too (panel round 2,
            # N16: measure the side before mono_below, so the report says
            # whether the lows were mono already)
            side_text = side_in ? "#{db_text.(side_in)} in the mix, #{db_text.(side)} mastered" : db_text.(side)
            lines << format('  true peak %.2f dBTP (ceiling %.1f), side below %d Hz %s re mid', true_peak, ceiling.db_value, side_hz, side_text)
            if reference
              lines << format('  like %s (%.1f LUFS, %.1f dBTP); tilt: reference %+.2f dB/oct, mix %s, EQ %s, mastered %s',
                              reference.name, reference.lufs, reference.true_peak, reference.tilt,
                              tilt_in ? format('%+.2f', tilt_in) : 'not measured', tilt ? format('%+.2f', tilt) : 'none',
                              tilt_out ? format('%+.2f', tilt_out) : 'n/a')
            end
            if sections
              lines << '  sections (mix LUFS -> target, mastered, trim):'
              num = ->(v) { v&.finite? ? format('%6.1f', v) : '     -' }
              sections.each do |r|
                lines << format('    %-14s %s -> %s, %s  %+6.2f dB', r[:label].to_s[0, 14], num.(r[:mix]), num.(r[:target]), num.(r[:level]), r[:trim])
              end
            end
            if codec_peaks
              lines << "  decoded true peaks: #{CodecPeaks.text(codec_peaks)} dBTP"
              CodecPeaks.notes(codec_peaks).each { |n| lines << "    #{n}" }
              unless codec_overs.empty?
                worst = codec_overs.values.max
                lines << format('  decoded peaks over %.1f dBTP clip in players: try ceiling: %.1f.db', CODEC_LIMIT, ceiling.db_value - (worst - CODEC_LIMIT) - 0.1)
              end
            end
            lines.join("\n")
          end
        end

        # Decoded true peaks above this (dBTP) get ceiling advice.
        CODEC_LIMIT = -0.1

        # Finds the trim (see Targeting) for the chains +capture+ recorded
        # in +session+ (the first pass's, closed), measured from frame
        # +origin+.  +target+ overrides the presets' (a Loudness::Target);
        # +post_gain+ is the master gain when it applies after the chain.
        def self.solve(session, capture, origin: 0, target: nil, post_gain: 1.0)
          records = capture.targeted
          presets = capture.presets
          raise ArgumentError, 'No targeted mastering preset ran in the render' if presets.empty?

          targets = presets.map { |p| p.target.lufs }.uniq
          if targets.length > 1 && target.nil?
            warn "The render's mastering presets have different targets (#{targets.map { |t| format('%.1f', t) }.join(', ')} LUFS); using the last one's"
          end
          target ||= presets.last.target
          ceiling = presets.map(&:ceiling).min_by(&:db_value)
          limited = presets.all?(&:limiter)

          inexact = records.reject { |r| tail_of(r) }
          unless inexact.empty?
            warn "The master chain (#{inexact.first.chain.description}) doesn't end with its mastering preset, so the loudness target is found by rebuilding the whole chain; nodes in it that read knobs, buses, or players make that approximate"
          end

          base, length = mix_from(capture, origin, session.channels)
          # :match: the tilt EQ's correction from the mix entering the trim
          tilt = tilt_in = nil
          if presets.last.measured_tilt?
            tilt, tilt_in = Mastering.tilt_correction(presets.last.reference, trim_input(records.last, origin, length), sample_rate: session.sample_rate)
          end
          # What the target measures (Mastering::MEASURES): with :loudest,
          # the loudest +loudest_bars+ bars, windows starting on bar lines;
          # with :bars, a percentile of the single bars' levels
          mode = presets.last.measure
          bars = presets.last.loudest_bars
          # with :sections, the loudest section pass of the song form first
          # (then each section's own trim; see .solve_sections)
          sections = mode == :sections ? section_ranges(capture, records.last, origin, length, session.sample_rate) : nil
          if mode == :sections && sections.nil?
            warn 'measure: :sections needs a song form playing in the render (flow); measuring the loudest bars instead'
            mode = :loudest
          end
          window = case mode
                   when :loudest then loudest_windows(session.transport, origin, length, session.sample_rate, bars)
                   when :bars then bar_windows(session.transport, origin, length, session.sample_rate, presets.last.percentile)
                   when :sections then { ranges: [sections[:ranges][sections[:loudest]]] }
                   end
          first = measure(base, session.sample_rate, true_peak: false, loudest: window)[0]
          runs = 0
          # +db+ is the trim in dB, or a TrimCurve
          output = ->(db) {
            runs += 1
            out = base.map(&:dup)
            gain = db.is_a?(TrimCurve) ? db : db.db.to_f
            records.each { |r| add_chain(session, r, gain, out, origin, length, post_gain, tilt: tilt) }
            out
          }
          eval = ->(db, peak = !limited) { measure(output.(db), session.sample_rate, true_peak: peak, loudest: window) }

          drive = presets.last.drive
          x0 = drive.db_value
          f0 = first
          x1 = (x0 + (target.lufs - f0)).clamp(x0 - RANGE, x0 + RANGE)
          f1, tp = eval.(x1)
          MAX_STEPS.times do
            break if !f1.finite? || (f1 - target.lufs).abs <= TOLERANCE
            slope = (f1 - f0) / (x1 - x0)
            # The limiters are saturated (more trim no longer adds
            # loudness): keep the smaller trim and report the miss
            if x1 > x0 && slope.finite? && slope < 0.05
              x1, f1 = x0, f0 if f0.finite? && f1 <= f0 + 0.05
              tp = nil
              break
            end
            slope = 1.0 if !slope.finite? || slope < 0.05
            x2 = (x1 + (target.lufs - f1) / slope).clamp(x0 - RANGE, x0 + RANGE)
            x0, f0 = x1, f1
            x1 = x2
            f1, tp = eval.(x1)
          end

          trims = nil
          rows = nil
          if mode == :sections
            trims, rows = solve_sections(sections, x1, target.lufs, presets.last.energy, output, session.sample_rate, session.transport)
            f1 = rows[sections[:loudest]][:level]
            tp = limited ? nil : measure(output.(trims), session.sample_rate, true_peak: true)[1]
          end

          held = false
          unless limited
            4.times do
              break unless tp && tp > ceiling.db_value + TOLERANCE
              held = true
              x1 -= tp - ceiling.db_value
              if trims
                trims = TrimCurve.new(trims.points.map { |f, d| [f, d - (tp - ceiling.db_value)] })
                tp = measure(output.(trims), session.sample_rate, true_peak: true)[1]
              else
                f1, tp = eval.(x1)
              end
            end
          end
          # The whole report on the final trim
          out = output.(trims || x1)
          if trims
            a_sec = Loudness::Analyzer.new(channels: out.length, sample_rate: session.sample_rate, true_peak: false)
            a_sec.process(out)
            levels = a_sec.loudness_in(sections[:ranges])
            rows = rows.each_with_index.map { |r, i| r.merge(level: levels[i]) }
            x1 = rows[sections[:loudest]][:trim]
          end
          a = Loudness::Analyzer.new(channels: out.length, sample_rate: session.sample_rate)
          a.process(out)
          r = a.result
          hz = presets.last.options.fetch(:mono) { Mastering.preset_settings(presets.last.name).dig(:defaults, :mono) } || 120
          side = out.length == 2 ? Genre.low_side_db(out, frequency: hz, sample_rate: session.sample_rate) : nil
          input = input_from(records.last, origin, length)
          side_in = input.length == 2 ? Genre.low_side_db(input, frequency: hz, sample_rate: session.sample_rate) : nil

          Result.new(
            preset: presets.last.name, trim: x1.db, target: target, ceiling: ceiling,
            integrated: r.integrated, short_term_max: r.short_term_max, range: r.range, true_peak: r.true_peak,
            side: side, side_hz: hz, first_pass: first, runs: runs, held: held, codec_peaks: nil,
            measure: mode, loudest: window ? loudest_of(a, window) : nil, loudest_bars: mode == :loudest ? bars : nil,
            drive: drive, percentile: mode == :bars ? presets.last.percentile : nil, side_in: side_in,
            trims: trims, sections: rows&.map(&:freeze)&.freeze, energy: mode == :sections ? presets.last.energy : nil,
            reference: presets.last.reference, tilt: tilt, tilt_in: tilt_in,
            tilt_out: presets.last.reference ? Analysis::Spectrum.new(out, sample_rate: session.sample_rate).tilt : nil
          )
        end

        # The section passes of measure: :sections over a render of +length+
        # frames from session frame +origin+ (from +capture+'s marks; see
        # Capture#note_sections): { labels:, starts: (session frames),
        # ranges: ([start, end] seconds from the render's first frame),
        # mix: (each pass's loudness in +record+'s chain input, the mix
        # before mastering), loudest: (index) }, or nil without a form.
        def self.section_ranges(capture, record, origin, length, sample_rate)
          marks = capture.sections.select { |f, _| f < origin + length }
          return nil if marks.empty?

          marks = marks.map { |f, l| [[f, origin].max, l] }
          marks.unshift([origin, '(before)']) if marks[0][0] > origin
          # (passes that start where the render does keep the last one)
          marks = marks.reverse.uniq(&:first).reverse
          bounds = marks.map(&:first) + [origin + length]
          ranges = marks.each_index.map { |i| [(bounds[i] - origin).to_f / sample_rate, (bounds[i + 1] - origin).to_f / sample_rate] }

          input = input_from(record, origin, length)
          a = Loudness::Analyzer.new(channels: input.length, sample_rate: sample_rate, true_peak: false)
          a.process(input)
          mix = a.loudness_in(ranges).map { |v| v&.finite? ? v : nil }
          return nil if mix.compact.empty?

          loudest = mix.each_with_index.select(&:first).max_by(&:first).last
          { labels: marks.map(&:last), starts: marks.map(&:first), ranges: ranges, mix: mix, loudest: loudest }
        end

        # Per-section trims for measure: :sections: each section pass
        # within Mastering::BARS_RANGE LU of the loudest (in the mix) gets
        # the target +lufs+ + +energy+ x (its mix level - the loudest's),
        # so energy 1 keeps the mix's distance between sections and 0
        # brings them all to the target; quieter passes (silence, tails)
        # take the trim of the pass before them, and no pass's trim goes
        # more than SECTION_MAX_LIFT over the loudest's.  Starting from +base+ (the
        # trim that brings the loudest pass to the target), a few secant
        # steps per section on its loudness through the chain (+output+, a
        # callable taking a TrimCurve).  Returns [TrimCurve, rows (one Hash
        # per pass: label, mix, target, trim, level)].
        def self.solve_sections(sections, base, lufs, energy, output, sample_rate, transport)
          n = sections[:ranges].length
          top = sections[:mix][sections[:loudest]]
          targets = sections[:mix].map { |m| m && m >= top - BARS_RANGE ? lufs + energy * (m - top) : nil }
          ramp = ramp_frames(transport, sample_rate)
          levels_of = ->(curve) {
            out = output.(curve)
            a = Loudness::Analyzer.new(channels: out.length, sample_rate: sample_rate, true_peak: false)
            a.process(out)
            a.loudness_in(sections[:ranges])
          }
          fill = ->(trims) {
            trims.each_index.map { |i| targets[i] ? trims[i] : (trims[0...i].reverse.zip(targets[0...i].reverse).find { |_, t| t }&.first || trims[targets.index { |t| t }]) }
          }
          trims = Array.new(n, base.to_f)
          levels = levels_of.(curve_of(sections, trims, ramp))
          slopes = Array.new(n, 1.0)
          SECTION_STEPS.times do
            capped = trims[sections[:loudest]] + SECTION_MAX_LIFT - 1e-9
            errs = targets.each_with_index.map { |t, i|
              next 0.0 unless t && levels[i]&.finite?
              e = t - levels[i]
              e > 0 && trims[i] >= capped ? 0.0 : e # (held at SECTION_MAX_LIFT)
            }
            break if errs.all? { |e| e.abs <= SECTION_TOLERANCE }

            moved = trims.each_index.map { |i| (trims[i] + errs[i] / slopes[i]).clamp(base - RANGE, base + RANGE) }
            lift = moved[sections[:loudest]] + SECTION_MAX_LIFT
            moved = fill.(moved).map { |t| [t, lift].min }
            new_levels = levels_of.(curve_of(sections, moved, ramp))
            n.times do |i|
              dx = moved[i] - trims[i]
              next unless dx.abs > 1e-3 && new_levels[i]&.finite? && levels[i]&.finite?
              slopes[i] = ((new_levels[i] - levels[i]) / dx).clamp(0.05, 2.0)
            end
            trims, levels = moved, new_levels
          end
          rows = n.times.map { |i|
            { label: sections[:labels][i], mix: sections[:mix][i], target: targets[i], trim: trims[i], level: levels[i] }
          }
          [curve_of(sections, trims, ramp), rows]
        end

        # The TrimCurve for per-section +trims+ (dB): ramps of +ramp+
        # frames at each section start toward the lower trim first (see
        # TrimCurve), shortened to a quarter of a short section.
        def self.curve_of(sections, trims, ramp)
          starts = sections[:starts]
          points = [[starts[0], trims[0]]]
          (1...starts.length).each do |i|
            b = starts[i]
            prev, nxt = trims[i - 1], trims[i]
            next if prev == nxt
            span = [b - starts[i - 1], (starts[i + 1] || (b + ramp * 4)) - b].min
            r = [ramp, span / 4].min
            if nxt < prev
              points << [b - r, prev] << [b, nxt]
            else
              points << [b, prev] << [b + r, nxt]
            end
          end
          TrimCurve.new(points)
        end

        # SECTION_RAMP as frames at +transport+'s tempo (a quarter note;
        # 0.25 s without a transport).
        def self.ramp_frames(transport, sample_rate)
          seconds = transport ? (SECTION_RAMP / transport.whole_notes_per_second).to_f : 0.25
          (seconds * sample_rate).round
        end

        # The input +record+'s chain received (the mix before the master
        # chain) from frame +origin+, +length+ frames, as channels.
        def self.input_from(record, origin, length)
          out = Array.new(record.inputs[0].length) { Numo::SFloat.zeros(length) }
          record.frames.each_with_index do |frame, i|
            data = record.inputs[i]
            count = data[0].length
            next if frame + count <= origin || frame - origin >= length

            skip = [origin - frame, 0].max
            at = frame + skip - origin
            n = [count - skip, length - at].min
            data.each_with_index { |d, ch| out[ch][at...(at + n)] = d[skip...(skip + n)] }
          end
          out
        end

        # What +record+'s preset received at its trim from frame +origin+,
        # +length+ frames, as channels (the Tap's buffers when the chain
        # ends with the preset, else the chain's input).
        def self.trim_input(record, origin, length)
          b = tail_of(record)
          return input_from(record, origin, length) unless b

          out = Array.new(b.tap.buffers[0]&.length || 0) { Numo::SFloat.zeros(length) }
          record.frames.each_with_index do |frame, i|
            data = b.tap.buffers[i]
            count = data[0].length
            next if frame + count <= origin || frame - origin >= length

            skip = [origin - frame, 0].max
            at = frame + skip - origin
            n = [count - skip, length - at].min
            data.each_with_index { |d, ch| out[ch][at...(at + n)] = d[skip...(skip + n)] }
          end
          out
        end

        # The recorded mix from frame +origin+ as full-length channels.
        # Returns [channels, length].
        def self.mix_from(capture, origin, channels)
          rows = capture.mix.select { |frame, d| frame + d[0].length > origin }
          length = rows.sum { |frame, d| frame + d[0].length - [frame, origin].max }
          out = Array.new(channels) { Numo::SFloat.zeros(length) }
          rows.each do |frame, d|
            skip = [origin - frame, 0].max
            at = frame + skip - origin
            d.each_with_index { |c, i| out[i][at...(at + c.length - skip)] = c[skip..] }
          end
          [out, length]
        end

        # The one targeted preset whose output is +record+'s chain's output
        # and whose Tap recorded every buffer (the chain can then be run
        # again from the trim on), or nil.
        def self.tail_of(record)
          targeted = record.built.select { |b| b.preset.targeted? }
          return nil unless targeted.length == 1
          b = targeted[0]
          return nil unless b.tap && b.tap.buffers.length == record.frames.length
          outs = b.output.respond_to?(:outputs) ? b.output.outputs : [b.output]
          outs = outs * record.chain.nodes.length if outs.length == 1
          outs.length == record.chain.nodes.length && outs.zip(record.chain.nodes).all? { |a, n| a.equal?(n) } ? b : nil
        end

        # Runs a recorded chain again with trim +gain+ (linear) and adds the
        # difference from its recorded outputs into +out+ (from frame
        # +origin+): from the recorded trim input through the preset's trim
        # and later steps when the chain ends with the preset (see
        # .tail_of), else the whole chain rebuilt from its block over its
        # recorded inputs (same random seeds; nodes that read knobs, buses,
        # or players see their state after the first pass, so such chains
        # are approximate: see .solve's check).
        def self.add_chain(session, record, gain, out, origin, length, post_gain, tilt: nil)
          if (b = tail_of(record))
            src = GraphNode::MixSource.new(channels: b.tap.outputs.length, sample_rate: session.sample_rate)
            result = b.preset.apply(GraphNode::Channels.new(src.outputs), trim: gain, from_trim: true, session: session,
              tilt: b.preset.measured_tilt? ? tilt : nil)
            nodes = result.respond_to?(:outputs) ? result.outputs : [result]
            nodes *= record.chain.nodes.length if nodes.length == 1
            run = ->(i, count) {
              src.write(b.tap.buffers[i])
              cache = {}
              nodes.map { |n| cache[n.__id__] ||= n.sample(count) }
            }
          else
            old = session.mastering_trim
            old_tilt = session.mastering_tilt
            old_capture = session.mastering_capture
            c = nil
            begin
              MB::Sound.keeping_random_state do
                Internal.restore_rng(record.chain.rng.dup) if record.chain.rng
                session.mastering_trim = gain
                session.mastering_tilt = tilt
                session.mastering_capture = nil
                Session.with_context(session: session) { c = session.send(:build_master, record.chain.block, preset: record.chain.preset) }
              end
            ensure
              session.mastering_trim = old
              session.mastering_tilt = old_tilt
              session.mastering_capture = old_capture
            end
            run = ->(i, count) { session.send(:master_chain_output, c, record.inputs[i], count) }
          end

          record.frames.each_with_index do |frame, i|
            count = record.inputs[i][0].length
            gain.frame_override = frame if gain.is_a?(TrimCurve)
            data = run.(i, count)
            ramp = record.ramps[i]
            next if frame + count <= origin || frame - origin >= length

            skip = [origin - frame, 0].max
            at = frame + skip - origin
            n = [count - skip, length - at].min
            data.each_with_index do |d, ch|
              d = d * ramp if ramp
              diff = (d[skip...(skip + n)] - record.outputs[i][ch][skip...(skip + n)])
              diff = diff * post_gain if post_gain != 1
              out[ch][at...(at + n)] = out[ch][at...(at + n)] + diff
            end
          end
        ensure
          gain.frame_override = nil if gain.is_a?(TrimCurve)
        end

        # [integrated LUFS, true peak dBTP or nil] of +channels+; with
        # +loudest+ (see .loudest_windows), the loudest window's LUFS
        # instead of the integrated loudness.
        def self.measure(channels, sample_rate, true_peak:, loudest: nil)
          a = Loudness::Analyzer.new(channels: channels.length, sample_rate: sample_rate, true_peak: true_peak)
          a.process(channels)
          [loudest ? loudest_of(a, loudest) : a.integrated, true_peak ? a.true_peak : nil]
        end

        # The windows of measure: :loudest over a render of +length+ frames
        # from session frame +origin+: +bars+ bars starting on each bar line
        # of +transport+ (through its meter map, at its current tempo) that
        # fits, as { ranges: [[start, end], ...] } in seconds from the
        # render's first frame; without a transport, { seconds: } windows
        # of that many bars' length every second (Analyzer#loudest).  A
        # render shorter than the window measures the whole (the
        # integrated loudness).
        def self.loudest_windows(transport, origin, length, sample_rate, bars)
          unless transport
            return { seconds: bars * 2.0, hop: 1.0 } # (4/4 at 120 BPM)
          end

          wnps = transport.whole_notes_per_second
          start_pos = Rational(origin, sample_rate.to_i) * wnps
          end_pos = Rational(origin + length, sample_rate.to_i) * wnps
          b = transport.bar_at(start_pos).ceil
          ranges = []
          loop do
            from = transport.bar_position(b)
            to = transport.bar_position(b + bars)
            break if to > end_pos
            ranges << [((from - start_pos) / wnps).to_f, ((to - start_pos) / wnps).to_f]
            b += 1
          end
          { ranges: ranges }
        end

        # The windows of measure: :bars (see Mastering::MEASURES): every
        # whole bar of the render (as .loudest_windows with one bar; 2 s
        # steps without a transport) and the +percentile+.
        def self.bar_windows(transport, origin, length, sample_rate, percentile)
          spec = loudest_windows(transport, origin, length, sample_rate, 1)
          unless spec[:ranges]
            seconds = length.to_f / sample_rate
            spec = { ranges: (0...(seconds / 2.0).floor).map { |i| [i * 2.0, (i + 1) * 2.0] } }
          end
          spec.merge(percentile: percentile)
        end

        # Analyzer +a+'s level per +spec+: the loudest window (see
        # .loudest_windows), or with +:percentile+ (see .bar_windows) the
        # level that share of the windows within Mastering::BARS_RANGE LU
        # of the loudest sit at or under (nearest rank; the integrated
        # loudness when no window holds a block).
        def self.loudest_of(a, spec)
          return a.loudest(spec[:seconds], hop: spec[:hop]) unless spec[:ranges]
          return a.loudest_in(spec[:ranges]) unless spec[:percentile]

          levels = a.loudness_in(spec[:ranges]).compact.select(&:finite?)
          return a.integrated if levels.empty?

          top = levels.max
          levels = levels.select { |l| l >= top - BARS_RANGE }.sort
          levels[((levels.length - 1) * spec[:percentile]).round]
        end
      end
    end
  end
end

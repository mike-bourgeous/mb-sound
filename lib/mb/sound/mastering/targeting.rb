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
        Result = Data.define(:preset, :trim, :target, :ceiling, :integrated, :short_term_max, :range, :true_peak, :side, :side_hz,
                             :first_pass, :runs, :held, :codec_peaks) do
          # Peak-to-loudness ratio (LU).
          def plr
            true_peak - integrated
          end

          # True if the loudness is within 0.5 LU of the target (or the
          # ceiling held it under) and the true peak is under the ceiling
          # (within 0.1 dB, the limiter's tolerance).
          def pass?
            (held || (integrated - target.lufs).abs <= 0.5) && true_peak <= ceiling.db_value + 0.1
          end

          # The decoded peaks over -0.1 dBTP (players clip them), or {}.
          def codec_overs
            (codec_peaks || {}).select { |_c, tp| tp > CODEC_LIMIT }
          end

          def to_s
            lines = []
            lines << format('mastering %s: %s (trim %+.2f dB; first pass %.2f LUFS, %d chain runs)',
                            preset.inspect, pass? ? 'pass' : 'FAIL', trim.db_value, first_pass, runs)
            lines << format('  loudness %.2f LUFS (target %.1f%s), short-term max %.1f, LRA %.1f LU, PLR %.1f LU',
                            integrated, target.lufs, held ? format(', held by the %.1f dBTP ceiling: no limiter', ceiling.db_value) : '',
                            short_term_max, range, plr)
            side_text = side ? (side.finite? ? format('%.1f dB', side) : '-inf dB') : 'n/a'
            lines << format('  true peak %.2f dBTP (ceiling %.1f), side below %d Hz %s re mid', true_peak, ceiling.db_value, side_hz, side_text)
            if codec_peaks
              text = codec_peaks.map { |c, tp| format('%s %.2f', c, tp) }.join(', ')
              lines << "  decoded true peaks: #{text} dBTP"
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
          first = measure(base, session.sample_rate, true_peak: false)[0]
          runs = 0
          output = ->(db) {
            runs += 1
            out = base.map(&:dup)
            records.each { |r| add_chain(session, r, db.db.to_f, out, origin, length, post_gain) }
            out
          }
          eval = ->(db, peak = !limited) { measure(output.(db), session.sample_rate, true_peak: peak) }

          x0 = presets.last.drive.db_value
          f0 = first
          x1 = (x0 + (target.lufs - f0)).clamp(x0 - RANGE, x0 + RANGE)
          f1, tp = eval.(x1)
          MAX_STEPS.times do
            break if !f1.finite? || (f1 - target.lufs).abs <= TOLERANCE
            slope = (f1 - f0) / (x1 - x0)
            slope = 1.0 if !slope.finite? || slope < 0.05
            x2 = (x1 + (target.lufs - f1) / slope).clamp(x0 - RANGE, x0 + RANGE)
            x0, f0 = x1, f1
            x1 = x2
            f1, tp = eval.(x1)
          end

          held = false
          unless limited
            4.times do
              break unless tp && tp > ceiling.db_value + TOLERANCE
              held = true
              x1 -= tp - ceiling.db_value
              f1, tp = eval.(x1)
            end
          end
          # The whole report on the final trim
          out = output.(x1)
          a = Loudness::Analyzer.new(channels: out.length, sample_rate: session.sample_rate)
          a.process(out)
          r = a.result
          hz = presets.last.options.fetch(:mono) { DEFINITIONS[presets.last.name][:defaults][:mono] } || 120
          side = out.length == 2 ? Genre.low_side_db(out, frequency: hz, sample_rate: session.sample_rate) : nil

          Result.new(
            preset: presets.last.name, trim: x1.db, target: target, ceiling: ceiling,
            integrated: r.integrated, short_term_max: r.short_term_max, range: r.range, true_peak: r.true_peak,
            side: side, side_hz: hz, first_pass: first, runs: runs, held: held, codec_peaks: nil
          )
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
        def self.add_chain(session, record, gain, out, origin, length, post_gain)
          if (b = tail_of(record))
            src = GraphNode::MixSource.new(channels: b.tap.outputs.length, sample_rate: session.sample_rate)
            result = b.preset.apply(GraphNode::Channels.new(src.outputs), trim: gain, from_trim: true)
            nodes = result.respond_to?(:outputs) ? result.outputs : [result]
            nodes *= record.chain.nodes.length if nodes.length == 1
            run = ->(i, count) {
              src.write(b.tap.buffers[i])
              cache = {}
              nodes.map { |n| cache[n.__id__] ||= n.sample(count) }
            }
          else
            old = session.mastering_trim
            old_capture = session.mastering_capture
            c = nil
            begin
              MB::Sound.keeping_random_state do
                Internal.restore_rng(record.chain.rng.dup) if record.chain.rng
                session.mastering_trim = gain
                session.mastering_capture = nil
                Session.with_context(session: session) { c = session.send(:build_master, record.chain.block, preset: record.chain.preset) }
              end
            ensure
              session.mastering_trim = old
              session.mastering_capture = old_capture
            end
            run = ->(i, count) { session.send(:master_chain_output, c, record.inputs[i], count) }
          end

          record.frames.each_with_index do |frame, i|
            count = record.inputs[i][0].length
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
        end

        # [integrated LUFS, true peak dBTP or nil] of +channels+.
        def self.measure(channels, sample_rate, true_peak:)
          a = Loudness::Analyzer.new(channels: channels.length, sample_rate: sample_rate, true_peak: true_peak)
          a.process(channels)
          [a.integrated, true_peak ? a.true_peak : nil]
        end
      end
    end
  end
end

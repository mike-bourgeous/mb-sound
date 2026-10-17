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
          ChainRecord = Struct.new(:chain, :frames, :inputs, :outputs, :ramps) do
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
          def chain(chain)
            return nil if @check # (the second pass only checks graphs)
            ChainRecord.new(chain, [], [], [], []).tap { |r| @chains << r }
          end

          # Records the mix leaving the Session at +frame+ (a tap).
          def add_mix(frame, data)
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

        # The outcome of .solve: the +trim+ (Decibels), the +target+
        # (Loudness::Target) and +ceiling+ (Decibels), the predicted
        # integrated loudness and true peak of the render, the first pass's
        # loudness, the number of chain runs, and +held+ (true when the
        # ceiling, not the target, set the trim).
        Result = Data.define(:trim, :target, :ceiling, :integrated, :true_peak, :first_pass, :runs, :held) do
          def to_s
            tp = true_peak ? format(', %.2f dBTP', true_peak) : ''
            held_text = held ? format(' (held under the %.1f dBTP ceiling without a limiter)', ceiling.db_value) : ''
            format('mastering: trim %+.2f dB for %.1f LUFS -> %.2f LUFS%s%s (first pass %.2f LUFS; %d chain runs)',
                   trim.db_value, target.lufs, integrated, tp, held_text, first_pass, runs)
          end
        end

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

          base, length = mix_from(capture, origin, session.channels)
          first = measure(base, session.sample_rate, true_peak: false)[0]
          runs = 0
          eval = ->(db, peak = !limited) {
            runs += 1
            out = base.map(&:dup)
            records.each { |r| add_chain(session, r, db.db.to_f, out, origin, length, post_gain) }
            measure(out, session.sample_rate, true_peak: peak)
          }

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
          f1, tp = eval.(x1, true) if tp.nil?

          Result.new(trim: x1.db, target: target, ceiling: ceiling, integrated: f1, true_peak: tp, first_pass: first, runs: runs, held: held)
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

        # Rebuilds a recorded chain with trim +gain+ (linear), runs it over
        # its recorded inputs, and adds the difference from its recorded
        # outputs into +out+ (from frame +origin+).
        def self.add_chain(session, record, gain, out, origin, length, post_gain)
          old = session.mastering_trim
          old_capture = session.mastering_capture
          c = nil
          MB::Sound.keeping_random_state do
            Internal.restore_rng(record.chain.rng.dup) if record.chain.rng
            session.mastering_trim = gain
            session.mastering_capture = nil
            c = session.send(:build_master, record.chain.block, preset: record.chain.preset)
          end

          record.frames.each_with_index do |frame, i|
            input = record.inputs[i]
            count = input[0].length
            data = session.send(:master_chain_output, c, input, count)
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
          session.mastering_trim = old
          session.mastering_capture = old_capture
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

require 'digest'
require 'fileutils'

module MB
  module Sound
    module HandTune
      # A refine pass on a tuned track (hand-tune-2; see RefineMethods#refine):
      # an optimizer (CMA-ES, Search) starting from his knob values, inside
      # his limits, against the track's reference, run in the worker
      # process (Worker; measured: the console's render thread keeps its
      # deadlines) or here (+mode: :here+, for scripts: it competes for the
      # GVL).  Its result is a proposal: printed as one grouped `turn` line,
      # A/B-able three ways (#ab: his settings, the proposal on a muted
      # copy of the track, the reference), applied only when asked
      # (#apply: one journaled change, one undo step).
      #
      # Takes record what was found, not the search: the line that ran the
      # search is kept as `refine(:kick, proposal: { ... }, searched: "...")`
      # once its result is known, #apply as `refine(:kick, apply: { ... })`,
      # so a replay plays what was heard without searching again.
      class Refinement
        # Significant figures of proposed values (the printed line, the A/B
        # copy, and #apply use the same numbers).
        FIGURES = 5

        # Seconds between progress redraws.
        REDRAW = 0.25

        attr_reader :track, :job, :result, :state, :error, :mode, :searched, :line

        # +session+ and +track+; +job+ (a RefineJob to search), or
        # +proposal+ ({ param => value }: a search's result given again, as
        # takes keep it); +mode+ :worker or :here.
        def initialize(session, track, job: nil, proposal: nil, searched: nil, mode: :worker)
          @session = session
          @track = track
          @job = job
          @mode = mode
          @proposal = proposal&.transform_keys(&:to_sym)
          @searched = searched
          @result = nil
          @error = nil
          @state = proposal ? :done : :new
          @progress = nil
          @stop = false
          @thread = nil
          @worker = nil
          @alt = nil
          @line = nil
          @base = job&.values
        end

        # [evaluations, best loss, start loss, seconds] so far (nil before
        # the first).
        def progress = @progress

        # True once the search ended (or for a given proposal).
        def done? = %i[done failed].include?(@state)

        # Starts the search (see the class description).  Returns self.
        def start
          raise ArgumentError, 'refine: nothing to search' unless @job
          _take, @line = Session.context&.take_line
          @state = :running
          @t0 = MB::U.clock_now
          if @mode == :here
            @thread = Thread.new do
              finish(HandTune.refine_run(@job, stop: -> { @stop }, progress: ->(e, b, s, t) { @progress = [e, b, s, t] }))
            rescue StandardError => e
              fail_with("#{e.class}: #{e.message}")
            end
          else
            @worker = Worker.start
            @thread = Thread.new {
              unless @worker.wait_ready
                fail_with('the refine worker did not start')
                next
              end
              @worker.submit(@job)
              loop do
                m = @worker.next_message(0.5) or next
                if m['progress']
                  @progress = m['progress']
                elsif m['result']
                  finish(RefineResult.from_json_data(m['result']))
                  break
                elsif m['error']
                  fail_with(m['error'])
                  break
                end
              end
            }
          end
          @thread.name = 'MB::Sound::HandTune::Refinement'
          self
        end

        # Waits for the search to end, redrawing one progress line on +io+
        # when it animates (best loss so far, evaluations, time left).
        # Ctrl-C stops it, keeping the best so far.  Returns self.
        def wait(io: $stdout)
          animate = ColorPolicy.animate?(io)
          shown = false
          begin
            until done?
              @thread&.join(REDRAW)
              if animate && (p = @progress)
                io.write("\r\e[K#{progress_text(p)}")
                io.flush
                shown = true
              end
            end
          rescue Interrupt
            stop
            retry
          end
          if shown
            io.write("\r\e[K")
            io.flush
          end
          self
        end

        # Stops the search; its best so far is the proposal.
        def stop
          @stop = true
          @worker&.stop if @state == :running
          self
        end

        # { param => value } the search proposes (changed params only,
        # rounded to FIGURES), or nil before it ends.
        def proposal
          return @proposal if @proposal
          return nil unless @result
          base = @base || {}
          @proposal = @result.values.each_with_object({}) { |(p, v), h|
            next unless v.is_a?(Numeric)
            r = MB::M.sigfigs(v.to_f, FIGURES)
            b = base[p]
            h[p] = r unless b.is_a?(Numeric) && MB::M.sigfigs(b.to_f, FIGURES) == r
          }
        end

        # The proposal as one console line (`turn :kick, tune: 47.9,
        # decay: 0.412`), or nil.
        def turn_line
          pr = proposal or return nil
          return nil if pr.empty?
          "turn #{@track.inspect}, #{HandTune.keywords_ruby(pr)}"
        end

        # The A/B copy's track (:"kick_refined").
        def alt_name = :"#{@track}_refined"

        # Flips the track's A/B to the next of his settings, the proposal
        # (on a muted copy of the track, set up on the first flip,
        # loudness-matched to his patch), and the reference; +to+ (:patch,
        # :alt, :ref) picks one.  Returns the Reference::Pair.
        def ab(to = nil)
          pr = proposal or raise ArgumentError, "refine #{@track.inspect}: nothing proposed yet (#{@state})"
          pair = Reference.pair(@session, @track) or raise ArgumentError, "refine #{@track.inspect}: no reference to A/B against (ab #{@track.inspect}, 'ref.wav')"
          setup_alt(pair, pr) unless pair.alt
          Reference.flip(@session, @track, to: to)
        end

        # Turns the track's knobs to the proposal as one change (journaled,
        # one undo step: build knobs rebuild the track once), stops the A/B
        # copy, and hears the patch.  Returns self.
        def apply
          pr = proposal or raise ArgumentError, "refine #{@track.inspect}: nothing proposed yet (#{@state})"
          code = "refine(#{@track.inspect}, apply: { #{HandTune.keywords_ruby(pr)} })"
          Take.record_call_as(:apply, code, receiver: true) { |n| n.receiver.is_a?(Prism::CallNode) && n.receiver.name == :refine }
          pairs = pr.to_h { |p, v| [Session::Name.param(@track, p), v] }
          pair = Reference.pair(@session, @track)
          Session.with_context(session: @session) do
            @session.command("refine #{@track.inspect} applied") do
              @session.turn_knobs(pairs)
              if pair&.alt
                MB::Sound.stop(pair.alt)
                MB::Sound.unmute(pair.track)
                MB::Sound.mute(pair.ref)
                pair.alt = nil
                pair.hearing = :patch
              end
            end
          end
          @applied = true
          self
        end

        # Stops the A/B copy (the patch is heard).  Returns self.
        def off
          pair = Reference.pair(@session, @track)
          if pair&.alt
            Session.with_context(session: @session) do
              @session.command("refine #{@track.inspect}, :off") do
                MB::Sound.stop(pair.alt)
                MB::Sound.unmute(pair.track)
                MB::Sound.mute(pair.ref)
              end
            end
            pair.alt = nil
            pair.hearing = :patch
          end
          self
        end

        def to_s
          case @state
          when :failed then return "refine #{@track.inspect}: failed: #{@error}"
          when :running, :new then return progress_text(@progress) + ' (refine.wait, refine.stop)'
          end
          pr = proposal || {}
          head = if @result
                   r = @result
                   terms = r.terms.map { |k, (a, b)| "#{k} #{format('%.3f', a)} -> #{format('%.3f', b)}" }.join(', ')
                   why = { evals: 'its evaluations', time: 'its time', stop: 'stopped' }[r.ended]
                   "refine #{@track.inspect}: loss #{format('%.3f', r.start)} -> #{format('%.3f', r.best)} (#{terms}) in #{r.evals} evaluations, " \
                     "#{format('%.1f', r.seconds)} s (#{why})"
                 else
                   "refine #{@track.inspect}: proposed#{@searched ? " (#{@searched})" : ''}"
                 end
          return "#{head}; nothing moved (your settings are the best it found)" if pr.empty?
          moved = pr.map { |p, v| b = @base&.[](p); b.is_a?(Numeric) ? "#{p} #{Take::Reader.number(b)} -> #{Take::Reader.number(v)}" : "#{p} -> #{Take::Reader.number(v)}" }
          [head, "  #{moved.join(', ')}", "  #{turn_line}",
           "refine.ab (yours -> refined -> reference; b in the inspector), refine.apply (one undo step), refine.off"].join("\n")
        end

        def inspect = "#<HandTune::Refinement #{@track.inspect} #{@state}#{proposal ? " #{proposal.length} knobs" : ''}>"

        # The take line that ran the search, rewritten as what it found
        # (see the class description): `refine(:kick, proposal: {...},
        # searched: "...")`.
        def recorded_line
          "refine(#{@track.inspect}, proposal: { #{HandTune.keywords_ruby(proposal || {})} }, searched: #{searched_text.inspect})"
        end

        private

        def searched_text
          r = @result
          j = @job
          return @searched.to_s unless r && j
          parts = []
          parts << "seconds: #{RubyValue.to_ruby(j.budget)}" if j.budget
          parts << "evals: #{j.evals}" if j.evals
          parts << "seed: #{j.seed}"
          parts << "#{r.evals} evaluations, loss #{format('%.4f', r.start)} -> #{format('%.4f', r.best)}"
          parts.join(', ')
        end

        def progress_text(p)
          return "refine #{@track.inspect}: starting" unless p
          e, best, start, t = p
          left = @job&.budget ? ", #{format('%.0f', [@job.budget - t, 0].max)} s left" : ''
          of = @job&.evals ? "/#{@job.evals}" : ''
          loss = best && start ? ", loss #{format('%.3f', start)} -> #{format('%.3f', best)}" : ''
          "refine #{@track.inspect} #{format('%.1f', t)} s: #{e}#{of} evaluations#{loss}#{left} (Ctrl-C keeps the best)"
        end

        def finish(result)
          @result = result
          @state = :done
          # (the take keeps what was found, not the search)
          @line.code = rewrite(@line.code) if @line
        end

        def rewrite(code)
          tree = Prism.parse(code)
          return code unless tree.success?
          node = nil
          stack = [tree.value]
          until stack.empty?
            n = stack.shift
            if n.is_a?(Prism::CallNode) && n.name == :refine && n.receiver.nil? && n.arguments
              node = n
              break
            end
            stack.concat(n.compact_child_nodes)
          end
          return code unless node
          src = code.b
          src[node.location.start_offset...node.location.end_offset] = recorded_line.b
          src.force_encoding(code.encoding)
        end

        def fail_with(message)
          @error = message
          @state = :failed
        end

        # The A/B copy: the track's instrument on +alt_name+ at the
        # proposal (the other knobs his), muted, playing the track's clip,
        # its level matched to his patch's loudness.
        def setup_alt(pair, pr)
          tr = @session.arrangement.tracks[@track] or raise ArgumentError, "refine: no track #{@track.inspect}"
          entry = Arrangement::InstrumentPatch.entry_of(tr.patch) or raise ArgumentError, "refine #{@track.inspect}: the track plays no instrument"
          alt = alt_name
          his = Reference.knob_values(@session, @track)
          values = his.merge(pr)
          path = Reference.document_path(@session, @track)
          seconds = pair.sample.seconds.to_f.clamp(Reference::MIN_SECONDS, Reference::MATCH_SECONDS)
          n, vel, hold = Reference.note_of(@session, @track)
          a = Reference.lufs(HandTune.render(path, his, note: n, velocity: vel, hold: hold, seconds: seconds), RATE)
          b = Reference.lufs(HandTune.render(path, values, note: n, velocity: vel, hold: hold, seconds: seconds), RATE)
          level = a.finite? && b.finite? ? (a - b).clamp(-60.0, 12.0) : 0.0
          Session.with_context(session: @session) do
            @session.command("refine #{@track.inspect} A/B") do
              MB::Sound.track(alt, entry)
              values.each { |p, v|
                k = @session.knobs[Session::Name.param(alt, p)] or next
                k.set(v, frame: k.next_frame) unless k.value == v
              }
              MB::Sound.mute(alt)
              MB::Sound.level(alt, Decibels.new(level))
              MB::Sound.bg(alt, tr.clip) if tr.clip
            end
          end
          pair.alt = alt
        end
      end

      module_function

      # +pairs+ ({ name => value }) as Ruby keywords (`tune: 47.9, decay:
      # 0.412`; RubyValue).
      def keywords_ruby(pairs)
        pairs.map { |k, v| "#{k}: #{RubyValue.to_ruby(v)}" }.join(', ')
      end

      # The refine passes of each Session ({ Session => Refinement }: the
      # last one).
      def refinements
        @refinements ||= ObjectSpace::WeakKeyMap.new
      end

      # The RefineJob for track +track+ in +session+ (see
      # RefineMethods#refine for the options).
      def refine_job(session, track, seconds: nil, evals: nil, within: 0.2, only: nil, except: nil, ranges: {}, weights: nil, seed: 1, staged: false, length: nil)
        path = Reference.document_path(session, track) or
          raise ArgumentError, "refine: #{track.inspect} plays no graph document (tune #{track.inspect}, code, ...; or a preset)"
        doc = GraphIO.parse(path)
        pair = Reference.pair(session, track) or raise ArgumentError, "refine #{track.inspect}: no reference to refine against (ab #{track.inspect}, 'ref.wav'; or tune ..., ref:)"
        decls = doc.declarations.select { |_, p| p.is_a?(Param) && p.numeric? && p.bounded? }
        names = decls.keys
        bad = (Array(only) + Array(except) + ranges.keys).map(&:to_sym) - names
        unless bad.empty?
          raise ArgumentError, "refine #{track.inspect}: no knob #{bad.map(&:inspect).join(', ')} (its knobs: #{names.join(', ')})"
        end
        names &= Array(only).map(&:to_sym) if only
        names -= Array(except).map(&:to_sym)
        raise ArgumentError, "refine #{track.inspect}: no knobs left to refine" if names.empty?
        if within && !(within.is_a?(Numeric) && within > 0 && within <= 1)
          raise ArgumentError, "refine: within: is a share of each knob's range (0.2 = 20% either way; got #{within.inspect})"
        end
        values = Reference.knob_values(session, track)
        free = names.map { |p|
          spec = session.knobs[Session::Name.param(track, p)]&.spec
          range = spec ? spec.range : decls[p].range
          curve = spec ? spec.curve : Arrangement::TrackKnobs.curve_of(decls[p])
          curve = curve == :exp ? :exp : :linear
          lo = Param.magnitude(range.begin).to_f
          hi = Param.magnitude(range.end).to_f
          pos = Param::Scale.position(values.fetch(p).to_f, lo, hi, curve)
          if (r = ranges[p] || ranges[p.to_s])
            raise ArgumentError, "refine #{track.inspect}, #{p}: give a range (#{p}: 40..60; got #{r.inspect})" unless r.is_a?(Range) && r.begin && r.end
            a, b = [r.begin, r.end].map { |x| Param::Scale.position(Param.magnitude(x).to_f, lo, hi, curve).clamp(0.0, 1.0) }.sort
          elsif within
            a = (pos - within).clamp(0.0, 1.0)
            b = (pos + within).clamp(0.0, 1.0)
          else
            a = 0.0
            b = 1.0
          end
          [p, lo, hi, curve, a, b]
        }
        stages = case staged
                 when true then HandTune.blocks(File.read(path), names)
                 when Array then staged.map { |s| Array(s).map(&:to_sym) & names }.reject(&:empty?)
                 end
        seconds = 20 if seconds.nil? && evals.nil?
        ref = Analysis::Signal.from(pair.sample).data
        length ||= (ref.length.to_f / RATE).clamp(0.1, 2.0)
        n, vel, hold = Reference.note_of(session, track)
        data = Numo::SFloat.cast(ref).to_binary
        rpath = File.join(FitPatch.dir, 'refine', "#{track}-#{Digest::SHA256.hexdigest(data)[0, 12]}.f32")
        unless File.file?(rpath)
          FileUtils.mkdir_p(File.dirname(rpath))
          File.binwrite(rpath, data)
        end
        name = (doc.name || File.basename(path, GraphIO::EXTENSION)).to_sym
        RefineJob.new(name: name, document: File.read(path), reference: rpath, values: values, free: free, note: n, velocity: vel, hold: hold,
                      seconds: length.to_f, weights: weights&.transform_keys(&:to_sym), evals: evals, budget: seconds&.to_f, seed: seed, stages: stages)
      end
    end

    # The console's refine (MB::Sound extends it; hand-tune-2).
    module RefineMethods
      # An optimizer pass on top of your settings: from the knobs of track
      # +track+ as they are, against its reference (ab, or tune's ref:),
      # it searches (CMA-ES) for knob values the comparison (L3) calls
      # closer, within your limits, without disturbing what plays (it runs
      # in a worker process, started before playback by bin/sound.rb).
      # Nothing changes until you say: it prints the proposal as one
      # `turn` line, `refine.ab` flips between yours, the refined copy, and
      # the reference (b in the inspector too, once set up), and
      # `refine.apply` turns your knobs to it as one undo step.
      #
      # Limits: +seconds:+ (wall clock; 20 when neither is given) and/or
      # +evals:+; +within:+ (a trust region: each knob moves at most this
      # share of its range from where you put it, 0.2 by default; nil for
      # the whole range) or a range per knob (`tune: 40..60`); +only:+ /
      # +except:+ (knob names; default all the patch's knobs).  +staged:
      # true+ refines one block of knobs at a time (the code's calls: the
      # body, the click, the noise), or give the stages (`[[:tune, :decay],
      # [:tick]]`).  +weights:+ replaces L3's ({ spectral: 1, modulation:
      # 2, attack: 0.3 }); +seed:+ (1) makes a run repeatable at the same
      # +evals:+; +length:+ the seconds of the note compared (the
      # reference's, at most 2).  It waits, showing the best loss so far
      # (Ctrl-C stops it, keeping the best); +wait: false+ returns at once
      # (`refine` shows it, `refine.wait`).  +mode: :here+ searches in
      # this process (scripts; it competes with the render thread).
      #
      #     refine :kick, seconds: 20, within: 0.15
      #     refine.ab         # yours -> refined -> reference -> yours
      #     refine.apply      # one undo step
      #     refine :kick, evals: 300, only: [:tune, :decay], tune: 40..60
      #
      # Returns a HandTune::Refinement (it prints what it found); without
      # arguments, the last one.  Takes keep what was found
      # (`refine(:kick, proposal: { ... })`), not the search.
      def refine(track = nil, seconds: nil, evals: nil, within: 0.2, only: nil, except: nil, weights: nil, seed: 1, staged: false, length: nil,
                 wait: true, mode: :worker, proposal: nil, searched: nil, apply: nil, **ranges)
        session = Session.current
        if track.nil?
          return HandTune.refinements[session] || raise(ArgumentError, 'refine: nothing refined yet (refine :kick, seconds: 20)')
        end
        raise ArgumentError, "refine names a track: refine :kick, seconds: 20 (got #{track.inspect})" unless track.is_a?(Symbol)
        if (given = apply || proposal)
          r = HandTune::Refinement.new(session, track, proposal: given, searched: searched)
          HandTune.refinements[session] = r
          r.apply if apply
          return r
        end
        if Session.context&.replaying?
          puts "refine #{track.inspect}: a replay doesn't search (the take was saved before its search ended)"
          return nil
        end
        job = HandTune.refine_job(session, track, seconds: seconds, evals: evals, within: within, only: only, except: except, ranges: ranges,
                                  weights: weights, seed: seed, staged: staged, length: length)
        r = HandTune::Refinement.new(session, track, job: job, mode: mode)
        r.start
        HandTune.refinements[session] = r
        return r unless wait
        r.wait
        puts r.to_s
        r
      end
    end

    extend RefineMethods
  end
end

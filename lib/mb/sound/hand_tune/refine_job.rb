require 'json'

module MB
  module Sound
    module HandTune
      # One refine pass's work, as plain data (hand-tune-2): what a worker
      # process is sent (as JSON) and what .run searches in-process.  The
      # maintainer (2026-11-03): "optionally I'd like to be able to trigger
      # an optimizer pass with time or range limitations on top of my own
      # settings to refine them".
      #
      # +name+ (the fit's), +document+ (the document text playing), +reference+
      # (a raw little-endian float32 file of the reference, mono at 48 kHz),
      # +values+ ({ param => value }: his knobs, the search's start), +free+
      # (the params searched: [[param, range lo, range hi, curve, position
      # lo, position hi], ...]: each knob's range and curve, and the trust
      # region in its 0..1 positions), +note+, +velocity+, +hold+, +seconds+
      # (the note rendered), +weights+ (the comparison's; nil: L3's),
      # +evals+ (the most evaluations, nil: no limit but +budget+),
      # +budget+ (wall-clock seconds, nil: none), +seed+, +stages+ (lists of
      # params searched one after another, or nil: all at once).
      RefineJob = Data.define(:name, :document, :reference, :values, :free, :note, :velocity, :hold, :seconds, :weights, :evals, :budget, :seed, :stages) do
        # The job as JSON-able data (Symbols as Strings).
        def to_json_data
          to_h.merge(name: name.to_s, values: values.transform_keys(&:to_s), free: free.map { |f| [f[0].to_s, *f[1..3].map { |x| x.is_a?(Symbol) ? x.to_s : x }, *f[4..]] },
                     weights: weights&.transform_keys(&:to_s), stages: stages&.map { |s| s.map(&:to_s) })
        end

        # The job back from #to_json_data (parsed JSON).
        def self.from_json_data(h)
          h = h.transform_keys(&:to_sym)
          new(**h.merge(name: h[:name].to_sym, values: h[:values].transform_keys(&:to_sym),
                        free: h[:free].map { |f| [f[0].to_sym, f[1], f[2], f[3].to_sym, f[4], f[5]] },
                        weights: h[:weights]&.transform_keys(&:to_sym), stages: h[:stages]&.map { |s| s.map(&:to_sym) }))
        end

        # The free params' names.
        def params = free.map(&:first)

        # { param => value } at unit-cube point +u+ (each free param's
        # position from its trust region; the others his).
        def values_at(u)
          v = values.dup
          free.each_with_index { |(p, lo, hi, curve, plo, phi), i| v[p] = Param::Scale.value(plo + (phi - plo) * u[i], lo.to_f, hi.to_f, curve) }
          v
        end

        # His values as a unit-cube point.
        def start_point
          free.map { |p, lo, hi, curve, plo, phi|
            pos = Param::Scale.position(values.fetch(p).to_f, lo.to_f, hi.to_f, curve)
            phi == plo ? 0.5 : ((pos - plo) / (phi - plo)).clamp(0.0, 1.0)
          }
        end
      end

      # What a refine found: +values+ ({ param => value } at the best point:
      # all of the document's params), +start+ and +best+ (the comparison's
      # totals at his settings and at the best), +terms+ ({ term => [start,
      # best] }), +evals+, +seconds+ (wall clock), +ended+ (:evals, its
      # evaluations done; :time, its budget; :stop, stopped), +history+
      # ([[evaluation, best loss], ...]), +found_at+.
      RefineResult = Data.define(:values, :start, :best, :terms, :evals, :seconds, :ended, :history, :found_at) do
        def to_json_data = to_h.merge(values: values.transform_keys(&:to_s), terms: terms.transform_keys(&:to_s), ended: ended.to_s)

        def self.from_json_data(h)
          h = h.transform_keys(&:to_sym)
          new(**h.merge(values: h[:values].transform_keys(&:to_sym), terms: h[:terms].to_h { |k, v| [k.to_sym, v] }, ended: h[:ended].to_sym))
        end
      end

      module_function

      # Runs +job+ (a RefineJob) here: CMA-ES (Search) over its trust
      # region from his values, each point one note rendered offline from
      # the document (.render) and scored against the reference (.compare),
      # stage by stage when it has stages (the evaluations and the budget
      # split by their sizes, each stage starting from the best so far).
      # +stop+ (a Proc) ends it early, keeping the best so far; +progress+
      # is called with (evaluations, best loss, start loss, seconds) after
      # each evaluation.  Returns a RefineResult.
      def refine_run(job, stop: nil, progress: nil)
        t0 = MB::U.clock_now
        path = FitPatch.version_path(job.document, job.name)
        target = Analysis::Signal.new(Numo::DFloat.cast(Numo::SFloat.from_binary(File.binread(job.reference))), name: 'reference')
        weights = job.weights || Analysis::Comparison::WEIGHTS
        compare_at = ->(values) {
          snd = render(path, values, note: job.note, velocity: job.velocity, hold: job.hold, seconds: job.seconds)[0]
          compare(target, snd, weights: weights)
        }
        start_cmp = nil
        search = Search.new(job.free.length) { |u|
          c = compare_at.(job.values_at(u))
          start_cmp ||= c
          c.total
        }
        deadline = job.budget && t0 + job.budget
        stages = job.stages || [job.params]
        index = job.params.each_with_index.to_h
        dims = stages.sum(&:length).to_f
        x0 = job.start_point
        report = progress && ->(s) { progress.call(s.evals, s.best&.f, start_cmp&.total, MB::U.clock_now - t0) }
        over = -> { stop&.call || (deadline && MB::U.clock_now >= deadline) }
        stages.each_with_index do |names, k|
          free = names.map { |n| index.fetch(n) }
          share = names.length / dims
          evals = job.evals ? [(job.evals * share).round, 1].max : 1 << 40
          dl = deadline && (k == stages.length - 1 ? deadline : [MB::U.clock_now + job.budget * share, deadline].min)
          search.run(search.best&.u || x0, evals: evals, seed: job.seed + k, free: free, deadline: dl, stop: stop, progress: report)
          break if over.call
        end
        ended = stop&.call ? :stop : (deadline && MB::U.clock_now >= deadline ? :time : :evals)
        best = search.best
        raise ArgumentError, 'refine: no time for one evaluation (give it more seconds: or evals:)' unless best
        values = job.values_at(best.u)
        best_cmp = compare_at.(values)
        RefineResult.new(values: values, start: start_cmp.total, best: best_cmp.total, terms: start_cmp.terms.to_h { |k, v| [k, [v, best_cmp.terms[k]]] },
                         evals: search.evals, seconds: MB::U.clock_now - t0, ended: ended, history: search.history, found_at: best.at)
      end

      # The document's params in blocks (+text+'s body walked with Prism):
      # each param with the call it is an argument of (`h.body(tune,
      # decay: decay)`: tune and decay), an operator's operand with the
      # call it operates on (`h.noise(...) * tick`: tick with the noise), a
      # local's value with the local (`d = drive_gain`).  [[param, ...],
      # ...] in the order the blocks start: refine's stages (the voice-match
      # lesson: fit one layer, then the next layer's few knobs).
      def blocks(text, params)
        tree = Prism.parse(text)
        return [params] unless tree.success?
        groups = {}
        walk = ->(node, owner) {
          if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? && node.block.nil? && node.variable_call? && params.include?(node.name)
            (groups[owner] ||= []) << node.name unless groups[owner]&.include?(node.name)
            return
          end
          own = owner
          if node.is_a?(Prism::LocalVariableWriteNode)
            own = [:local, node.location.start_offset]
          elsif node.is_a?(Prism::CallNode) && !FitPatch::HEADER_CALLS.include?(node.name)
            if OPERATORS.include?(node.name)
              r = node.receiver
              own = r.is_a?(Prism::CallNode) && !OPERATORS.include?(r.name) ? [:call, r.location.start_offset] : owner
            else
              own = [:call, node.location.start_offset]
            end
          end
          node.compact_child_nodes.each { |c|
            # (a call's receiver chain belongs to its own calls)
            walk.(c, node.is_a?(Prism::CallNode) && c.equal?(node.receiver) ? owner : own)
          }
        }
        walk.(tree.value, [:top, 0])
        list = groups.sort_by { |(kind, at), _| [kind == :top ? 1 : 0, at] }.map(&:last)
        list.flat_map { |g| g & params }.uniq.length == params.length ? list : list + [params - list.flatten]
      end

      # Operator calls (an operand belongs with what it operates on).
      OPERATORS = %i[+ - * / ** % -@ +@].freeze
    end
  end
end

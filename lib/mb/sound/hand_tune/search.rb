module MB
  module Sound
    module HandTune
      # The voice-match study's search loop (research fit.rb's Fit#run,
      # 6ea917e0; hand-tune-2): CMA-ES in the unit cube from a start point,
      # restarting on stagnation (25 generations without a 1e-4 gain, or
      # every axis under 0.002) from a random point while over 40% of the
      # budget remains, else around the best so far with a small step.
      # Points outside the cube are scored at the clamped point plus a
      # quadratic penalty (10 x the squared distance outside).  Each run
      # scores its start point first, so a search never ends worse than
      # where it began.  The same seed and budget give the same best
      # (checked against the research code's numbers in search_spec).
      #
      # Added for refine: a +deadline:+ (a monotonic clock time) and a
      # +stop:+ Proc checked before each evaluation (the best so far
      # stands), +free:+ (the cube's coordinates the run moves, the others
      # held at the start point: a stage of a staged search), and a
      # +progress:+ Proc called after each evaluation.
      #
      #     s = Search.new(2) { |u| (u[0] - 0.3)**2 + (u[1] - 0.7)**2 }
      #     s.run([0.5, 0.5], evals: 300, seed: 1)
      #     s.best.u   # => [0.3, 0.7] (nearly)
      class Search
        # The best point so far: its loss +f+ (with the penalty), +u+
        # (clamped to the cube), and the evaluation it was found at (+at+,
        # counting from 1).
        Best = Data.define(:f, :u, :at)

        # The best point (Best, nil before the first evaluation), the
        # evaluations made, and the history ([[evaluation, best loss
        # rounded to 5 places], ...] at each improvement).
        attr_reader :best, :evals, :history, :dim

        # A search over +dim+ unit-cube coordinates scored by the block
        # (given a point clamped to the cube; returns its loss).
        def initialize(dim, &loss)
          raise ArgumentError, 'Search takes the loss as a block' unless loss
          @dim = dim
          @loss = loss
          @best = nil
          @evals = 0
          @history = []
          @stopped = false
        end

        # True if the last #run stopped at its deadline or its stop Proc
        # (not its budget).
        def stopped? = @stopped

        # The loss at unit-cube point +u+, recorded (see the class
        # description).
        def evaluate(u)
          f = @loss.call(u.map { |x| x.clamp(0.0, 1.0) })
          f = 1e3 unless f.is_a?(Numeric) && f.finite?
          record(u, f.to_f)
        end

        # Runs CMA-ES for about +evals+ evaluations from +x0+ (a point of
        # the cube), as the class description says.  +ipop+: each random
        # restart doubles the population (IPOP-CMA-ES).  Returns #best.
        def run(x0, evals:, seed: 1, sigma: 0.3, ipop: false, free: nil, deadline: nil, stop: nil, progress: nil)
          @stopped = false
          free ||= (0...@dim).to_a
          x0 = x0.map(&:to_f)
          lam = nil
          rng = Random.new(seed)
          start = @evals
          run_no = 0
          full = ->(sub) { v = x0.dup; free.each_with_index { |i, k| v[i] = sub[k] }; v }
          halt = -> { (deadline && MB::U.clock_now >= deadline) || stop&.call }
          while @evals - start < evals
            return stop!(progress) if halt.call
            evaluate(x0) # (the start point counts: a stage never ends worse than its start)
            progress&.call(self)
            es = CMAES.new(free.map { |i| x0[i] }, sigma: sigma, seed: seed * 1000 + run_no, lambda: lam)
            stale = 0
            last = Float::INFINITY
            while @evals - start < evals
              pop = es.ask
              fs = pop.map { |sub|
                return stop!(progress) if halt.call
                f = evaluate(full.(sub))
                progress&.call(self)
                f
              }
              es.tell(pop, fs)
              gen_best = fs.min
              if gen_best < last - 1e-4
                last = gen_best
                stale = 0
              else
                stale += 1
              end
              break if stale > 25 || es.stds.max < 2e-3
            end
            run_no += 1
            remaining = evals - (@evals - start)
            if remaining > 0.4 * evals
              x0 = x0.dup
              free.each { |i| x0[i] = rng.rand }
              sigma = 0.3
              lam = es.lambda * 2 if ipop
            else
              x0 = @best.u
              sigma = 0.05
            end
          end
          @best
        end

        private

        def stop!(progress)
          @stopped = true
          progress&.call(self)
          @best
        end

        def record(u, loss)
          @evals += 1
          pen = u.sum { |x| x < 0 ? x * x : (x > 1 ? (x - 1)**2 : 0.0) }
          f = loss + 10 * pen
          if @best.nil? || f < @best.f
            @best = Best.new(f: f, u: u.map { |x| x.clamp(0.0, 1.0) }.freeze, at: @evals)
            @history << [@evals, f.round(5)]
          end
          f
        end
      end
    end
  end
end

module MB
  module Sound
    module HandTune
      # CMA-ES: Hansen's (mu/mu_w, lambda) covariance matrix adaptation
      # evolution strategy, as in purecma.py, in plain Ruby Arrays (the
      # dimensions here are 2-30, so a cyclic Jacobi eigendecomposition
      # every few generations is cheap next to one render).  Ported from
      # the voice-match study (research-voice-match, research/voice-match/
      # cmaes.rb, 6ea917e0; hand-tune-2) operation for operation: the same
      # seed gives the same populations (Search's spec checks it against
      # the research code's numbers).  Its random draws come from its own
      # generator (Random.new(+seed+), Box-Muller), so a seed reruns a
      # search exactly; Search takes the seed from MB::Sound.next_seed.
      #
      #     es = CMAES.new([0.5, 0.5], sigma: 0.3, seed: 1)
      #     pop = es.ask
      #     es.tell(pop, pop.map { |x| loss(x) })
      class CMAES
        attr_reader :mean, :sigma, :generation, :dim, :lambda

        # +mean+ (the start point), +sigma+ (the step), +seed+, +lambda+
        # (the population; default 4 + 3 ln dim).
        def initialize(mean, sigma:, seed: 1, lambda: nil)
          @dim = n = mean.length
          @mean = mean.map(&:to_f)
          @sigma = sigma.to_f
          @rng = Random.new(seed)
          @lambda = lambda || 4 + (3 * Math.log(n)).floor
          @mu = @lambda / 2
          w = (0...@mu).map { |i| Math.log(@mu + 0.5) - Math.log(i + 1) }
          sw = w.sum
          @weights = w.map { |x| x / sw }
          @mueff = 1.0 / @weights.sum { |x| x * x }
          @cc = (4 + @mueff / n) / (n + 4 + 2 * @mueff / n)
          @cs = (@mueff + 2) / (n + @mueff + 5)
          @c1 = 2 / ((n + 1.3)**2 + @mueff)
          @cmu = [1 - @c1, 2 * (@mueff - 2 + 1 / @mueff) / ((n + 2)**2 + @mueff)].min
          @damps = 1 + 2 * [0, Math.sqrt((@mueff - 1) / (n + 1)) - 1].max + @cs
          @chin = Math.sqrt(n) * (1 - 1.0 / (4 * n) + 1.0 / (21 * n * n))
          @pc = Array.new(n, 0.0)
          @ps = Array.new(n, 0.0)
          @c = identity(n)
          @b = identity(n)
          @d = Array.new(n, 1.0)
          @generation = 0
          @evals = 0
          @eigen_at = 0
        end

        # The next population (Arrays of length dim).
        def ask
          update_eigen
          Array.new(@lambda) do
            z = Array.new(@dim) { gauss * 1.0 }
            y = mat_vec(@b, z.each_with_index.map { |zi, i| zi * @d[i] })
            @mean.each_with_index.map { |m, i| m + @sigma * y[i] }
          end
        end

        # Updates from +xs+ (the population from #ask) and their losses
        # +fs+.
        def tell(xs, fs)
          n = @dim
          @generation += 1
          @evals += xs.length
          order = (0...xs.length).sort_by { |i| fs[i] }
          old = @mean
          ys = order.first(@mu).map { |i| xs[i].each_with_index.map { |x, j| (x - old[j]) / @sigma } }
          yw = Array.new(n) { |j| ys.each_with_index.sum { |y, k| @weights[k] * y[j] } }
          @mean = old.each_with_index.map { |m, j| m + @sigma * yw[j] }

          # C^-1/2 yw = B D^-1 B^T yw
          bt = mat_t_vec(@b, yw)
          inv = mat_vec(@b, bt.each_with_index.map { |v, i| v / @d[i] })
          a = Math.sqrt(@cs * (2 - @cs) * @mueff)
          @ps = @ps.each_with_index.map { |p, j| (1 - @cs) * p + a * inv[j] }
          psn = Math.sqrt(@ps.sum { |p| p * p })
          hsig = psn / Math.sqrt(1 - (1 - @cs)**(2 * @generation)) / @chin < 1.4 + 2.0 / (n + 1) ? 1.0 : 0.0
          a = Math.sqrt(@cc * (2 - @cc) * @mueff)
          @pc = @pc.each_with_index.map { |p, j| (1 - @cc) * p + hsig * a * yw[j] }

          c1a = @c1 * (1 - (1 - hsig) * @cc * (2 - @cc))
          n.times do |i|
            (0..i).each do |j|
              v = (1 - c1a - @cmu) * @c[i][j] + @c1 * @pc[i] * @pc[j]
              ys.each_with_index { |y, k| v += @cmu * @weights[k] * y[i] * y[j] }
              @c[i][j] = @c[j][i] = v
            end
          end
          @sigma *= Math.exp([1.0, (@cs / @damps) * (psn / @chin - 1)].min)
        end

        # Largest/smallest axis ratio of the search distribution.
        def condition = (@d.max / @d.min)**2

        # Standard deviation along each coordinate.
        def stds = (0...@dim).map { |i| @sigma * Math.sqrt(@c[i][i]) }

        # Eigenvalues and eigenvectors (columns of the returned matrix) of
        # the symmetric matrix +a+ (cyclic Jacobi).
        def self.jacobi(a)
          n = a.length
          a = a.map(&:dup)
          v = Array.new(n) { |i| Array.new(n) { |j| i == j ? 1.0 : 0.0 } }
          60.times do
            off = 0.0
            n.times { |i| n.times { |j| off += a[i][j]**2 if i != j } }
            break if off < 1e-24

            (0...n).each do |p|
              ((p + 1)...n).each do |q|
                next if a[p][q].abs < 1e-300

                theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                t = (theta >= 0 ? 1.0 : -1.0) / (theta.abs + Math.sqrt(theta * theta + 1))
                c = 1 / Math.sqrt(t * t + 1)
                s = t * c
                n.times do |k|
                  akp = a[k][p]
                  akq = a[k][q]
                  a[k][p] = c * akp - s * akq
                  a[k][q] = s * akp + c * akq
                end
                n.times do |k|
                  apk = a[p][k]
                  aqk = a[q][k]
                  a[p][k] = c * apk - s * aqk
                  a[q][k] = s * apk + c * aqk
                end
                n.times do |k|
                  vkp = v[k][p]
                  vkq = v[k][q]
                  v[k][p] = c * vkp - s * vkq
                  v[k][q] = s * vkp + c * vkq
                end
              end
            end
          end
          [(0...n).map { |i| a[i][i] }, v]
        end

        private

        def gauss
          # Box-Muller
          u1 = @rng.rand
          u1 = @rng.rand while u1 <= 1e-300
          Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * @rng.rand)
        end

        def update_eigen
          return if @evals - @eigen_at < @lambda / (@c1 + @cmu) / @dim / 10

          @eigen_at = @evals
          vals, vecs = CMAES.jacobi(@c)
          @d = vals.map { |v| Math.sqrt([v, 1e-20].max) }
          @b = vecs
        end

        def identity(n) = Array.new(n) { |i| Array.new(n) { |j| i == j ? 1.0 : 0.0 } }

        def mat_vec(m, v) = m.map { |row| row.each_with_index.sum { |x, j| x * v[j] } }

        def mat_t_vec(m, v)
          out = Array.new(m.length, 0.0)
          m.each_with_index { |row, i| row.each_with_index { |x, j| out[j] += x * v[i] } }
          out
        end
      end
    end
  end
end

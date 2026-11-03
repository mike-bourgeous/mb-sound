module MB
  module Sound
    module Analysis
      # Does a distance agree with a listener?  Given labeled picks (for
      # each item a target, its candidates, and the candidate the listener
      # picked as closest), scores how often each distance ranks the pick
      # first (top-1), how many (pick, other) pairs it orders right, the
      # mean reciprocal rank of the pick, and one-sided p values of at
      # least that many top-1 hits and pairwise wins under random
      # rankings (exact: the distributions of sums of independent
      # per-item outcomes).  Ties count half.  Round 3's eval_prefs.rb
      # method, used to choose L3 (Comparison) over round 2's loss.
      #
      # Caveats, from round 3: 24 labeled items is a small set (11
      # families were tried, so a p of 0.005 is about 0.05 corrected for
      # the number tried); the picks were not blind (the listener knew
      # which candidate was which); candidates fitted to one original are
      # already close, so the test is of fine distinctions.  Weights
      # learned from such a set did not generalize (leave-one-out 9 of 24
      # against 15 for the fixed L3).  Write down the distance's predicted
      # pick before the listener hears a new set: that is the clean test.
      #
      #     items = [
      #       { target: 'orig.wav', candidates: { 'a' => 'a.wav', 'b' => 'b.wav' }, pick: 'b' },
      #       { scores: { 'x' => { spectral: 1.2, modulation: 0.3, attack: 0.9 }, 'y' => { ... } }, pick: 'y' },
      #     ]
      #     pr = Analysis::Preferences.new(items)
      #     pr.evaluate           # every term and L3 (Score rows)
      #     pr.evaluate(r2_heavy: { spectral: 1, modulation: 0.5 })
      #     puts pr
      class Preferences
        # One item: +name+, +scores+ ({ label => { term => value } }),
        # +pick+ (a label).
        Item = Data.define(:name, :scores, :pick)

        # One distance's agreement: +name+, +top1+ hits of +items+,
        # +pairs_right+ (ties count half) of +pairs+, +mrr+ (mean
        # reciprocal rank of the pick), +p_top1+ and +p_pairs+ (one-sided,
        # exact), +chance_top1+ (the expected hits of random rankings).
        Score = Data.define(:name, :top1, :items, :pairs_right, :pairs, :mrr, :p_top1, :p_pairs, :chance_top1) do
          def to_s
            format('%-24s top-1 %d/%d (chance %.1f), pairs %.0f%% of %d, MRR %.2f, p %.3f / %.3f',
                   name, top1, items, chance_top1, pairs > 0 ? 100.0 * pairs_right / pairs : 0, pairs, mrr, p_top1, p_pairs)
          end
        end

        attr_reader :items

        # +items+: Hashes with +:pick+ (a candidate's label) and either
        # +:scores+ ({ label => { term => value } }, e.g. Comparison#to_h)
        # or +:target+ and +:candidates+ (a Hash of labels to sounds,
        # compared here with Comparison); +:name+ optional.  Items whose
        # pick is not among their candidates raise.
        def initialize(items)
          @items = items.each_with_index.map { |it, i| item(it, i) }.freeze
        end

        # The default distances: each Comparison term alone, and L3.
        def self.default_scorers
          Comparison::TERMS.to_h { |t| [t, t] }.merge(timbre: :timbre, L3: Comparison::WEIGHTS)
        end

        # Score rows for +scorers+: { name => a term Symbol, a weights Hash
        # ({ term => weight }), or a Proc taking a candidate's scores Hash
        # and returning a distance }.
        def evaluate(scorers = Preferences.default_scorers)
          scorers.map { |name, s| score(name.to_s, scorer(s)) }
        end

        # The rank of each item's pick (1 = closest) under +scorer+ (as in
        # #evaluate), { item name => rank } (ties at half ranks).
        def ranks(scorer = Comparison::WEIGHTS)
          f = scorer(scorer)
          @items.to_h { |it| [it.name, pick_rank(it, f)] }
        end

        def to_s
          ["#{@items.length} labeled items, chance top-1 #{format('%.1f', chance)}", *evaluate.map(&:to_s)].join("\n")
        end

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{@items.length} items>"

        # P(X >= k) for X the number of successes of independent trials
        # with probabilities +probs+.
        def self.at_least_hits(probs, k)
          dist = [1.0]
          probs.each do |p|
            nxt = Array.new(dist.length + 1, 0.0)
            dist.each_with_index { |v, i| nxt[i] += v * (1 - p); nxt[i + 1] += v * p }
            dist = nxt
          end
          k = k.ceil
          k <= 0 ? 1.0 : dist[k..].to_a.sum
        end

        # P(W >= w) for W the sum of independent uniform integers on
        # 0...k for each k of +sizes+ (an item's pairwise wins when the
        # pick's rank is uniform).
        def self.at_least_sum(sizes, w)
          dist = [1.0]
          sizes.each do |k|
            nxt = Array.new(dist.length + k - 1, 0.0)
            dist.each_with_index { |v, i| k.times { |j| nxt[i + j] += v / k } }
            dist = nxt
          end
          w = w.ceil
          w <= 0 ? 1.0 : (dist[w..] || []).sum
        end

        private

        def chance = @items.sum { |it| 1.0 / it.scores.size }

        def item(it, i)
          name = it[:name] || "item #{i + 1}"
          pick = it.fetch(:pick) { raise ArgumentError, "#{name}: no pick:" }
          scores =
            if it[:scores]
              it[:scores].to_h { |label, s| [label, s.transform_keys(&:to_sym)] }
            elsif it[:target] && it[:candidates]
              target = Signal.from(it[:target])
              it[:candidates].to_h { |label, c| [label, Comparison.new(target, c).to_h] }
            else
              raise ArgumentError, "#{name}: pass scores: or target: and candidates:"
            end
          raise ArgumentError, "#{name}: pick #{pick.inspect} is not a candidate (#{scores.keys.map(&:inspect).join(', ')})" unless scores.key?(pick)
          raise ArgumentError, "#{name}: needs at least two candidates" if scores.size < 2
          Item.new(name: name, scores: scores.freeze, pick: pick)
        end

        def scorer(s)
          case s
          when Symbol then ->(h) { h.fetch(s) { raise ArgumentError, "No #{s.inspect} in the scores (#{h.keys.join(', ')})" } }
          when Hash then ->(h) { s.sum { |k, w| w.to_f * h.fetch(k.to_sym) { raise ArgumentError, "No #{k.inspect} in the scores" } } }
          when Proc then s
          else raise ArgumentError, "A scorer is a term Symbol, a weights Hash, or a Proc (got #{s.inspect})"
          end
        end

        # The pick's rank: 1 + candidates closer + half the ties.
        def pick_rank(it, f)
          v = it.scores.transform_values { |h| f.call(h).to_f }
          pv = v[it.pick]
          others = v.reject { |k, _| k == it.pick }.values
          1 + others.count { |q| q < pv } + 0.5 * others.count { |q| q == pv }
        end

        def score(name, f)
          top = 0
          rr = 0.0
          wins = 0.0
          pairs = 0
          @items.each do |it|
            r = pick_rank(it, f)
            top += 1 if r == 1
            rr += 1.0 / r
            k = it.scores.size
            pairs += k - 1
            wins += k - r
          end
          n = @items.length
          Score.new(name: name, top1: top, items: n, pairs_right: wins, pairs: pairs, mrr: n > 0 ? rr / n : 0.0,
                    p_top1: Preferences.at_least_hits(@items.map { |it| 1.0 / it.scores.size }, top),
                    p_pairs: Preferences.at_least_sum(@items.map { |it| it.scores.size }, wins), chance_top1: chance)
        end
      end
    end
  end
end

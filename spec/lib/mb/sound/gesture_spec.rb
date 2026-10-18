# Gesture curves (gesture-curves, agreed 2026-10-18): keyframe turns
# (`turn :space, 0 => 0.30, 1.n8 => 0.50, 1.n4 => 0.62`), fitting recorded
# gestures into the fewest keys within a tolerance, raw steps in takes,
# and smoothing a recorded gesture on purpose.
RSpec.describe(MB::Sound::Gesture, :aggregate_failures) do
  let(:spec) { MB::Sound::GraphNode::Knob::Spec.new(name: :space, default: 0.3) }
  let(:exp_spec) { MB::Sound::GraphNode::Knob::Spec.new(name: :cut, default: 800, range: 100..8000, curve: :exp) }
  let(:per_sample) { (120r / 240) / 48000 } # 120 BPM at 48 kHz: 1.n8 is 12000 frames
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session(buffer_size: 800)
    t = MB::Sound::Sequence::Transport.new(bpm: 120)
    MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: t, channels: 1,
                           buffer_size: buffer_size, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # Deterministic wiggly gestures: a held key's ramps with pauses, a
  # wobble, steps of mixed sizes.
  def gestures
    rng = Random.new(42)
    Array.new(12) do |k|
      v = 0.5
      t = 0
      Array.new(10 + rng.rand(60)) do |i|
        t += [800, 800, 1600, 400][rng.rand(4)] if i > 0
        v = (v + (k.even? ? 0.01 : rng.rand(-0.03..0.03))).clamp(0.0, 1.0)
        [t, Float(MB::Sound::GraphNode::Knob.number(v))]
      end
    end
  end

  def max_error(g, steps, s = spec)
    steps.map { |f, v| (s.position(g.value_at(f, s)) - s.position(v)).abs }.max
  end

  describe '.fit' do
    it 'keeps every step within the tolerance of the knob range, in the knob scale (1e-3 by default, 1e-4 when asked)' do
      expect(described_class::TOLERANCE).to eq(1e-3)
      gestures.each do |steps|
        g = described_class.fit(steps, spec)
        expect(max_error(g, steps)).to be <= described_class::TOLERANCE + 1e-12
        fine = described_class.fit(steps, spec, tolerance: 1e-4)
        expect(max_error(fine, steps)).to be <= 1e-4 + 1e-12
        expect(fine.keys.length).to be >= g.keys.length
        expect(g.keys.first).to eq(steps.first)
        expect(g.keys.last).to eq(steps.last)
        expect(g.keys.length).to be <= steps.length
      end
    end

    it 'simplifies a held key (a straight ramp) to two keys, and fits exponential knobs in octaves' do
      ramp = (0..32).map { |i| [i * 800, Float(MB::Sound::GraphNode::Knob.number(0.30 + i * 0.01))] }
      expect(described_class.fit(ramp, spec).keys).to eq([[0, 0.3], [25600, 0.62]])
      sweep = (0..40).map { |i| [i * 800, Float(MB::Sound::GraphNode::Knob.number(800 * 2**(i / 20.0)))] }
      g = described_class.fit(sweep, exp_spec)
      expect(g.keys.length).to eq(2)
      expect(max_error(g, sweep, exp_spec)).to be <= described_class::TOLERANCE
    end

    it 'fits the same keys every time (no wall-clock budget)' do
      gestures.each { |steps| expect(described_class.fit(steps, spec).keys).to eq(described_class.fit(steps.map(&:dup), spec).keys) }
    end

    it 'keeps the steps of stepped knobs, and with tolerance: 0' do
      steps = gestures[1]
      expect(described_class.fit(steps, spec, stepped: true).then { |g| [g.keys, g.curve] }).to eq([steps, :step])
      expect(described_class.fit(steps, spec, tolerance: 0).keys).to eq(steps)
    end
  end

  describe 'monotone cubic segments' do
    it 'never overshoot their keys or leave the range' do
      rng = Random.new(7)
      20.times do
        keys = Array.new(2 + rng.rand(8)) { |i| [i * 1000 + rng.rand(500), rng.rand.round(4)] }
        keys = keys.each_with_index.map { |(f, v), i| [i == 0 ? 0 : f, v] }
        g = described_class.new(keys)
        keys.each_cons(2) do |(fa, va), (fb, vb)|
          lo, hi = [va, vb].minmax
          ((fa + 1)..fb).step(7).each { |f| expect(g.value_at(f, spec)).to be_between(lo - 1e-12, hi + 1e-12) }
        end
      end
    end
  end

  describe 'printing' do
    it 'prints times in the most musical exact unit, values to 6 figures, and curve: only when not the default' do
      g = described_class.new([[0, 0.3], [12000, 0.5], [24000, 0.62]])
      expect(g.to_ruby(:space, per_sample: per_sample)).to eq('turn :space, 0 => 0.3, 1.n8 => 0.5, 1.n4 => 0.62')
      g = described_class.new([[0, 0.3], [480, 0.5]], curve: :linear)
      expect(g.to_ruby(:space, per_sample: per_sample)).to eq('turn :space, 0 => 0.3, 10.ms => 0.5, curve: :linear')
      # One unit per line: a key off the grid prints every time in ms, else in exact seconds
      g = described_class.new([[0, 0.3], [480, 0.5], [12000, 0.62]])
      expect(g.to_ruby(:space, per_sample: per_sample)).to eq('turn :space, 0 => 0.3, 10.ms => 0.5, 250.ms => 0.62')
      g = described_class.new([[0, 0.3], [800, 0.5], [12000, 0.62]])
      line = g.to_ruby(:space, per_sample: per_sample)
      expect(line).to eq('turn :space, 0 => 0.3, (1r/60).seconds => 0.5, (1r/4).seconds => 0.62')
      keys = MB::Sound::Take.console_binding.eval("{ #{line.delete_prefix('turn :space, ')} }")
      expect(described_class.from_hash(keys, per_sample: per_sample, rate: 48000).keys).to eq(g.keys)
      expect(described_class.new([[0, 0.42]]).to_ruby(:space, per_sample: per_sample)).to eq('turn :space, 0.42')
    end
  end

  describe 'keyframe turns' do
    it 'reach every key on its frame and play the same values at any buffer size' do
      runs = [800, [367, 368], 7].map do |sizes|
        s = new_session
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.knob(:space, 0.3)
          s.add(MB::Sound.knob(:space) * 1, name: :x)
          MB::Sound.turn(:space, 0 => 0.30, 1.n8 => 0.50, 1.n4 => 0.62, 3.n8 => 0.4)
        end
        sizes = Array(sizes).cycle
        out = []
        done = 0
        while done < 40000
          n = [sizes.next, 40000 - done].min
          out << s.process_buffer(n)[0].dup
          done += n
        end
        SpecBuffers.join(out)
      end
      expect(runs[1]).to eq(runs[0])
      expect(runs[2]).to eq(runs[0])
      expect([runs[0][0], runs[0][12000], runs[0][24000], runs[0][36000]]).to eq([0.3, 0.5, 0.62, 0.4].map { |v| Numo::SFloat[v][0] })
      g = described_class.new([[0, 0.3], [12000, 0.5], [24000, 0.62], [36000, 0.4]])
      (0...36000).step(37).each { |f| expect(runs[0][f]).to be_within(1e-6).of(g.value_at(f, spec)) }
    end

    it 'shapes segments with curve: (:linear, :step, or a Curve name)' do
      s = new_session
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.knob(:a, 0.0)
        MB::Sound.knob(:b, 0.0)
        s.add(MB::Sound.knob(:a) + MB::Sound.knob(:b) * 0, name: :x)
        MB::Sound.turn(:a, 0 => 0.0, 1.n8 => 1.0, curve: :linear)
        MB::Sound.turn(:b, 0 => 0.0, 1.n8 => 1.0, curve: :step)
      end
      3.times { s.process_buffer }
      a = s.knobs[:a]
      expect(a.value).to be_within(1e-6).of(2399 / 12000.0) # (straight: frame f of the segment is f / 12000)
      expect(s.knobs[:b].value).to eq(0.0)
      expect { MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:a, 0 => 0.1, curve: :wobbly) } }.to raise_error(ArgumentError, /gesture's curve/)
    end
  end

  describe 'recorded gestures' do
    # A held gesture on a knob in the mix, committed as one line.
    def perform(s, take, steps)
      b = MB::Sound::Take.console_binding
      line = ->(code) { MB::Sound::Session.with_context(session: s) { take.line(code, b) } }
      line.('knob :g, 0.3')
      line.('bg :x, knob(:g) * 1')
      code = nil
      90.times do |i|
        steps.fetch(i, []).each { |v| s.preview_turn(:g, v) }
        if i == 70
          code = s.gesture_line(:g)
          line.(code)
        end
        s.process_buffer
      end
      code
    end

    let(:held) { (10..50).step(2).to_h { |i| [i, [(0.3 + (i - 10) * 0.004).round(4)]] } }

    it 'print the fitted line, keep the raw steps for the take, and smooth on purpose in one undo step' do
      s = new_session
      take = MB::Sound::Take.new(session: s)
      code = perform(s, take, held)
      expect(code).to match(/\Aturn :g, 0 => 0\.3, \S+ => 0\.46\z/) # (a straight ramp: two keys)
      raw = s.journal.changes.find { |e| e.kind == :turn && e.data[:gesture] }.data[:raw]
      expect(raw.length).to eq(21)
      expect(take.gestures.map { |r| r[3] }).to eq([raw])

      MB::Sound::Session.with_context(session: s) { MB::Sound.smooth_gesture(:g) }
      expect(take.gestures).to eq([])
      MB::Sound::Session.with_context(session: s) { s.undo(on: :now) }
      expect(take.gestures.map { |r| r[3] }).to eq([raw])
      expect(MB::Sound::Session.with_context(session: s) { MB::Sound.smooth_gesture(:nothing_here) rescue :raised }).to eq(:raised)
    end

    it 'keep a stepped knob\'s steps in the line' do
      s = new_session
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.knob(:mode, 0.0)
        MB::Sound.knob(:mode).choose(:a, :b, :c)
      end
      s.preview_turn(:mode, 0.2)
      s.process_buffer
      s.preview_turn(:mode, 0.5)
      s.process_buffer
      s.preview_turn(:mode, 0.9)
      expect(s.gesture_line(:mode)).to eq('turn :mode, 0 => 0.2, (1r/60).seconds => 0.5, (1r/30).seconds => 0.9, curve: :step')
    end
  end
end

RSpec.describe(MB::Sound::GraphNode::Tremolo, :aggregate_failures) do
  let(:methods) { MB::Sound::GraphNode::TremoloMethods }

  # +count+ samples of +node+ in buffers of +size+ (each output channel)
  def take(node, count, size = 800)
    outs = node.respond_to?(:outputs) ? node.outputs : [node]
    outs.map { |o|
      bufs = []
      got = 0
      while got < count
        b = o.sample([size, count - got].min)
        break if b.nil?
        bufs << b.dup
        got += b.length
      end
      SpecBuffers.join(bufs)
    }
  end

  def db(v)
    20 * Math.log10(v)
  end

  describe '#tremolo' do
    it 'swings a sine evenly in dB between unity and the depth by default' do
      b = take(1.constant.tremolo(1, depth: 12.db), 48000)[0]
      expect(b[0]).to be_within(1e-6).of(10**(-6 / 20.0))
      expect(b[12000]).to be_within(1e-6).of(1)
      expect(b[24000]).to be_within(1e-6).of(10**(-6 / 20.0))
      expect(db(b[36000])).to be_within(1e-5).of(-12)
      expect(db(b.min)).to be_within(1e-4).of(-12)
      expect(b.max).to be <= 1
    end

    it 'reads depth like a ducking amount: -12.db and 12.db are 12 dB down, a bare number the trough gain' do
      ref = take(1.constant.tremolo(3, depth: -12.db), 4800)[0]
      expect(take(1.constant.tremolo(3, depth: 12.db), 4800)[0]).to eq(ref)
      expect(take(1.constant.tremolo(1, depth: 0.25), 48000)[0].min).to be_within(1e-6).of(0.25)
      expect { 1.constant.tremolo(3, depth: 6) }.to raise_error(ArgumentError, /ducking never boosts/)
    end

    it 'moves evenly in amplitude with law: :linear, reaching silence for a full cut' do
      b = take(1.constant.tremolo(1, depth: 0, law: :linear, shape: :triangle), 48000)[0]
      expect([b[0], b[12000], b[24000], b[36000]]).to eq([0.5, 1.0, 0.5, 0.0])
    end

    it 'stops a dB trough at the floor (-80 dB, Sony Amplitude Modulation at -inf)' do
      b = take(1.constant.tremolo(1, depth: 0), 48000)[0]
      expect(db(b.min)).to be_within(1e-4).of(-80)
      b = take(1.constant.tremolo(1, depth: (-Float::INFINITY).db, floor: -40.db), 48000)[0]
      expect(db(b.min)).to be_within(1e-4).of(-40)
      expect { 1.constant.tremolo(1, floor: 0.db) }.to raise_error(ArgumentError, /floor/)
    end

    it 'plays the library LFO shapes' do
      saw = take(1.constant.tremolo(1, depth: 0, law: :linear, shape: :saw), 48000)[0]
      expect(saw[12000]).to be_within(1e-6).of(0.75)
      expect(saw[36000]).to be_within(1e-6).of(0.25)
      sq = take(1.constant.tremolo(1, depth: 0, law: :linear, shape: :square), 48000)[0]
      expect([sq[100], sq[30000]]).to eq([1.0, 0.0])
      expect { 1.constant.tremolo(1, shape: :wobble) }.to raise_error(ArgumentError, /shape: is one of/)
    end

    it 'holds seeded random levels with shape: :random' do
      a = take(1.constant.tremolo(4, depth: 0, law: :linear, shape: :random, seed: 5), 24000)[0]
      b = take(1.constant.tremolo(4, depth: 0, law: :linear, shape: :random, seed: 5), 24000)[0]
      expect(a).to eq(b)
      expect(a[1000..11000].to_a.uniq.length).to be <= 2
      expect(a.max - a.min).to be > 0.05
    end

    it 'glides to each random level over 3 ms by default, smooth: overriding it and smooth: 0 the hard steps (effects-4)' do
      mk = ->(**o) { take(1.constant.tremolo(4, depth: 0, law: :linear, shape: :random, seed: 5, **o), 48000)[0] }
      soft = mk.()
      hard = mk.(smooth: 0)
      expect(mk.(smooth: 3.ms)).to eq(soft)
      expect(mk.(smooth: methods::RANDOM_SMOOTH)).to eq(soft)
      # hard steps at the cycle edges (12000 samples at 4 Hz)
      steps = (hard[1..] - hard[0...-1]).abs
      expect(steps.max).to be > 0.05
      expect(steps.to_a.each_index.select { |i| steps[i] > 0 }).to eq([11999, 23999, 35999].select { |i| steps[i] > 0 })
      # the same levels, reached 3 ms (144 samples) after each edge
      [12000, 24000, 36000].each { |e| expect(soft[e + 144 + 10]).to be_within(1e-5).of(hard[e + 144 + 10]) }
      expect((soft[1..] - soft[0...-1]).abs.max).to be < steps.max / 50
      slow = mk.(smooth: 10.ms)
      expect((slow[1..] - slow[0...-1]).abs.max).to be < (soft[1..] - soft[0...-1]).abs.max / 2
    end

    it 'glides between seeded random levels with shape: :smooth_random (effects-3)' do
      held = take(1.constant.tremolo(1.n16, depth: 18.db, shape: :random, seed: 3, smooth: 0), 36000)[0]
      a = take(1.constant.tremolo(1.n16, depth: 18.db, shape: :smooth_random, seed: 3), 36000)[0]
      b = take(1.constant.tremolo(1.n16, depth: 18.db, shape: :wander, seed: 3), 36000, 367)[0]
      expect(b).to eq(a)
      # the held levels' steps (up to 0.64 a sample) become glides
      expect((held[1..] - held[0...-1]).abs.max).to be > 0.3
      expect((a[1..] - a[0...-1]).abs.max).to be < 0.001
      # each held level is reached by the end of its cycle (a 16th: 6000 samples at 120 BPM)
      (1..5).each { |k| expect(a[6000 * k - 1]).to be_within(1e-4).of(held[6000 * k - 1]) }
      expect(a.min).to be >= held.min - 1e-6
      expect(a.max).to be <= held.max + 1e-6
      expect { 1.constant.tremolo(2.hz.lfo.at(1..3), shape: :smooth_random) }.to raise_error(ArgumentError, /fixed rate/)
    end

    it 'blends the :linear and :db laws with a number from 0 (:linear) to 1 (:db) (effects-3)' do
      m = Numo::SFloat.linspace(-1, 1, 9)
      gain = ->(law, depth = 12.db) { MB::Sound::GraphNode::Tremolo.new(1.constant, 0.constant, depth: depth, law: law).gain(m, nil, 9).dup }
      [0, 18.db].each do |depth|
        lin = gain.(:linear, depth)
        dbl = gain.(:db, depth)
        expect(gain.(0, depth).to_a).to eq(lin.to_a)
        expect(gain.(1, depth).to_a.zip(dbl.to_a).map { |x, y| (x - y).abs }.max).to be < 1e-6
        half = gain.(0.25, depth)
        9.times { |i| expect(half[i]).to be_within(1e-6).of(lin[i] * 0.75 + dbl[i] * 0.25) }
        expect(half[8]).to be_within(1e-7).of(1)
      end
      # a node depth too
      t = MB::Sound::GraphNode::Tremolo.new(1.constant, 0.constant, depth: 0.5.constant, law: 0.5)
      g = t.gain(m, Numo::SFloat.new(9).fill(0.25), 9)
      expect(g[0]).to be_within(1e-6).of(0.25)
      expect(g[4]).to be_within(1e-6).of((0.625 + 0.5) / 2)
      expect { 1.constant.tremolo(1, law: 1.5) }.to raise_error(ArgumentError, /0 to 1/)
    end

    it 'shapes the gain with a Curve law: trough + (1 - trough) curve(LFO from bottom to top) (effects-3)' do
      m = Numo::SFloat.linspace(-1, 1, 9)
      gain = ->(law, depth = 0) { MB::Sound::GraphNode::Tremolo.new(1.constant, 0.constant, depth: depth, law: law).gain(m, nil, 9).dup }
      lin = gain.(:linear, 12.db)
      gain.(MB::Sound::Curve[:linear], 12.db).each_with_index { |v, i| expect(v).to be_within(1e-7).of(lin[i]) }
      sq = gain.(:sqrt)
      9.times { |i| expect(sq[i]).to be_within(1e-6).of(Math.sqrt(i / 8.0)) }
      expect(gain.(MB::Sound::Curve.power(0.5)).to_a).to eq(sq.to_a)
      t = 10**(-12 / 20.0)
      bounce = gain.(:bounce, 12.db)
      c = MB::Sound::Curve[:bounce]
      9.times { |i| expect(bounce[i]).to be_within(1e-6).of(t + (1 - t) * c.call(i / 8.0)) }
      back = gain.(MB::Sound::Curve[:back, overshoot: 1])
      expect(back.min).to eq(0) # (stops at 0 below)
      b = take(1.constant.tremolo(1, depth: 0, law: :sqrt, shape: :triangle), 48000)[0]
      expect([b[0], b[12000], b[36000]].map { |v| v.round(6) }).to eq([Math.sqrt(0.5).round(6), 1.0, 0.0])
      expect(1.constant.tremolo(1, law: :sqrt).to_s).to include('law power(0.5)')
      expect { 1.constant.tremolo(1, law: :sqr) }.to raise_error(ArgumentError, /law: .*Unknown curve :sqr/)
    end

    it 'follows the tempo for musical lengths' do
      MB::Sound.bpm(120)
      b = take(1.constant.tremolo(1.n4, depth: 0, law: :linear, shape: :triangle), 24000)[0]
      expect([b[0], b[6000], b[12000], b[18000]]).to eq([0.5, 1.0, 0.5, 0.0])
    ensure
      MB::Sound.rewind
    end

    it 'reads a Length as one cycle, as every modulation effect does (ModulationLfo)' do
      a = take(1.constant.tremolo(0.25.seconds, depth: 0, law: :linear, shape: :triangle), 12000)[0]
      b = take(1.constant.tremolo(4, depth: 0, law: :linear, shape: :triangle), 12000)[0]
      expect(a).to eq(b)
      expect { 1.constant.tremolo(0.seconds) }.to raise_error(ArgumentError, /Length per cycle/)
    end

    it 'starts at phase:' do
      b = take(1.constant.tremolo(1, depth: 0, law: :linear, shape: :triangle, phase: 0.25), 24000)[0]
      expect(b[0]).to eq(1.0)
    end

    it 'leads the right channel by stereo_phase:, making a mono input stereo' do
      t = 1.constant.tremolo(1, depth: 0, law: :linear, shape: :triangle, stereo_phase: 0.25)
      expect(t).to be_a(MB::Sound::GraphNode::Channels)
      l, r = take(t, 48000)
      expect([l[0], r[0]]).to eq([0.5, 1.0])
      expect(r[0...36000]).to eq(l[12000...48000])
    end

    it 'runs each channel of a bundle with its own phase' do
      l, r = take(MB::Sound.stereo(1.constant, 2.constant).tremolo(1, depth: 0, law: :linear, shape: :triangle, stereo_phase: 0.5), 24000)
      # (the right input is 2: its LFO starts half a cycle on, falling through the middle)
      expect([l[0], r[0], l[12000], r[12000]]).to eq([0.5, 1.0, 1.0, 0.0])
      expect(r[6000]).to eq(0.5)
    end

    it 'takes a node of the trough gain as depth:' do
      b = take(1.constant.tremolo(1, depth: 0.5.constant, law: :linear, shape: :triangle), 48000)[0]
      expect(b[36000]).to eq(0.5)
      b = take(1.constant.tremolo(1, depth: 0.25.constant, shape: :triangle), 48000)[0]
      expect(b[36000]).to be_within(1e-6).of(0.25)
    end

    it 'mixes the tremolo with the dry signal through blend (mix:)' do
      b = take(1.constant.tremolo(1, depth: 0, law: :linear, shape: :triangle, mix: 0.4), 48000)[0]
      expect(b[36000]).to be_within(1e-6).of(0.6)
      expect(b[12000]).to be_within(1e-6).of(1)
      expect(1.constant.tremolo(1, mix: 0.4).to_ruby).to include('tremolo(1, mix: 0.4)')
    end

    it 'mixes a mono input with its stereo tremolo (stereo_phase: and mix:)' do
      t = 1.constant.tremolo(1, depth: 0, law: :linear, shape: :triangle, stereo_phase: 0.5, mix: 0.5)
      expect(t.channel_count).to eq(2)
      l, r = take(t, 12000)
      expect([l[0], r[0], l[6000], r[6000]]).to eq([0.75, 0.75, 0.875, 0.625])
    end

    it 'leaves a frozen input buffer alone' do
      src = 1.constant
      t = src.tremolo(1, depth: 0, law: :linear)
      allow(src).to receive(:sample).and_wrap_original { |m, n| m.call(n).dup.freeze }
      expect { take(t, 800) }.not_to raise_error
    end

    it 'gives the same samples at any buffer size' do
      mk = -> { 220.hz.tremolo(7.3, shape: [[0, 1], [0.3, -1], [0.7, 0.2], [1, 1]], seam: 0.2, stereo_phase: 0.3, depth: 30.db) }
      ref = take(mk.(), 9000, 800)
      [367, 1].each do |size|
        got = take(mk.(), 9000, size)
        expect(got).to eq(ref)
      end
    end

    it 'prints and loads as written' do
      t = 110.hz.saw.trem(1.n8, depth: 6.db, shape: [[0, 1], [0.5, -1], [1, 1]], seam: true, stereo_phase: 0.5)
      text = t.to_ruby
      # (aliases record as the method's own name)
      expect(text).to include('tremolo(1.n8, depth: 6.db, shape: [[0, 1], [0.5, -1], [1, 1]], seam: true, stereo_phase: 0.5)')
      ref = take(t, 4000)
      MB::Sound.rewind
      expect(take(RecipeHelpers.eval_recipe(text), 4000)).to eq(ref)

      # effects-3's settings
      t = 110.hz.saw.trem(1.n8, law: MB::Sound::Curve[:back, overshoot: 0.3], shape: :smooth_random, seed: 2) +
        110.hz.saw.trem(1.n16, law: 0.3, shape: [[0, -1], [1, 1]], seam: :auto)
      text = t.to_ruby
      expect(text).to include('law: Curve[:back, overshoot: 0.3], shape: :smooth_random, seed: 2)').and include('law: 0.3, shape: [[0, -1], [1, 1]], seam: :auto)')
      ref = take(t, 4000)
      MB::Sound.rewind
      expect(take(RecipeHelpers.eval_recipe(text), 4000)).to eq(ref)
    end

    it 'raises for seam: on a named shape and for bad rates' do
      expect { 1.constant.tremolo(1, seam: true) }.to raise_error(ArgumentError, /drawn shapes/)
      expect { 1.constant.tremolo('fast') }.to raise_error(ArgumentError, /rate/)
      expect { 1.constant.tremolo(1, law: :log) }.to raise_error(ArgumentError, /law/)
    end
  end

  describe 'drawn shapes' do
    it 'joins the points with straight lines, in dB with the :db law' do
      b = take(1.constant.tremolo(1, depth: 24.db, shape: [[0, -1], [1, 1]]), 48000)[0]
      expect(db(b[0])).to be_within(1e-4).of(-24)
      expect(db(b[24000])).to be_within(1e-4).of(-12)
      expect(db(b[36000])).to be_within(1e-4).of(-6)
    end

    it 'blends the wrap over seam: of a cycle with a straight line (as Sony "blend graph edges" plays a sawtooth)' do
      b = take(1.constant.tremolo(1, depth: 24.db, shape: [[0, -1], [1, 1]], seam: 0.1), 48000)[0]
      # measured on Sony's render: -1.2 dB at 0.95, -22.8 dB at 0.05, a dB line between
      expect(db(b[45600])).to be_within(1e-3).of(-1.2)
      expect(db(b[2400])).to be_within(1e-3).of(-22.8)
      expect(db(b[0])).to be_within(1e-3).of(-12)
      expect(db(b[46800])).to be_within(1e-3).of(-6.6)
      expect(db(b[24000])).to be_within(1e-3).of(-12)
    end

    describe 'seam_mode: :jump (tremolo-seam-1)' do
      # The table's values (the shape with its seam) at +x+ cycles
      def table_at(shape, x, **opts)
        t = methods.drawn_table(shape, **opts)
        t.frames[0, (x * methods::DRAWN_SIZE).round]
      end

      it 'takes out only the jump between the ends, half on each side, keeping the shape\'s lines' do
        shape = [[0, -1], [0.5, 1], [1, 0]] # ends 0 and -1: a jump of 1 at the wrap
        { 0.97 => (1 - 0.47 / 0.5) - 0.2, 0.99 => (1 - 0.49 / 0.5) - 0.4, 0.02 => (-1 + 0.04 * 2) + 0.3, 0.04 => (-1 + 0.08 * 2) + 0.1 }.each do |x, want|
          expect(table_at(shape, x, seam: 0.1, mode: :jump)).to be_within(1e-6).of(want), x.to_s
        end
        expect(table_at(shape, 0, seam: 0.1, mode: :jump)).to be_within(1e-6).of(-0.5) # (both sides meet at the ends' average)
        expect(table_at(shape, 0.5, seam: 0.1, mode: :jump)).to eq(table_at(shape, 0.5))
        # continuous across the wrap: no step bigger than the steepest line's
        data = methods.drawn_table(shape, seam: 0.1, mode: :jump).frames[0, true]
        steps = (data[1..] - data[0...-1]).abs.to_a << (data[0] - data[-1]).abs
        expect(steps.max).to be < 21.0 / methods::DRAWN_SIZE * 1.01 # (the seam's ramp of 1 per 0.1 cycle plus the line's 2 per cycle; 1.01 for float32)
      end

      it 'plays a shape whose ends meet as drawn and keeps a trough at the wrap (the straight line cuts it)' do
        tri = [[0, -1], [0.5, 1], [1, -1]]
        expect(methods.drawn_table(tri, seam: 0.1, mode: :jump).frames).to eq(methods.drawn_table(tri).frames)
        jump = take(1.constant.tremolo(1, depth: 24.db, shape: tri, seam: 0.1, seam_mode: :jump), 48000)[0]
        line = take(1.constant.tremolo(1, depth: 24.db, shape: tri, seam: 0.1), 48000)[0]
        expect(db(jump[0])).to be_within(1e-3).of(-24)
        expect(db(line[0])).to be_within(1e-3).of(-24 * 0.9) # (the line from 0.95 to 0.05 holds the trough 2.4 dB up)
      end

      it 'agrees with the straight line for a sawtooth (the one shape where the two readings match)' do
        saw = [[0, -1], [1, 1]]
        a = methods.drawn_table(saw, seam: 0.1, mode: :jump).frames
        b = methods.drawn_table(saw, seam: 0.1).frames
        expect((a - b).abs.max).to be < 1e-6
        expect(methods.drawn_table(saw, seam: 0.1, mode: :jump)).not_to equal(methods.drawn_table(saw, seam: 0.1))
      end

      it 'clamps to the shape range, raises for unknown modes, prints, and gives the same output at any buffer size' do
        expect(table_at([[0, 0], [0.02, 1], [0.5, -1], [1, 1]], 0.02, seam: 0.1, mode: :jump)).to eq(1) # (1 + 0.3, clamped)
        expect { 1.constant.tremolo(1, shape: [[0, 1], [1, -1]], seam: 0.1, seam_mode: :smooth) }.to raise_error(ArgumentError, /seam_mode/)
        t = 110.hz.saw.trem(1.n8, depth: 6.db, shape: [[0, 1], [0.5, -1], [1, 0]], seam: true, seam_mode: :jump)
        expect(t.to_ruby).to include('seam: true, seam_mode: :jump)')
        loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(t))
        expect(take(loaded, 4800)).to eq(take(t, 4800))
        mk = -> { 220.hz.tremolo(7.3, shape: [[0, 1], [0.3, -1], [0.7, 0.2], [1, -0.6]], seam: 0.2, seam_mode: :jump, depth: 30.db) }
        ref = take(mk.(), 9600, 800)
        expect(take(mk.(), 9600, 367)).to eq(ref)
        expect(take(mk.(), 9600, 1)).to eq(ref)
      end
    end

    it 'evaluates points around the cycle, jumps from either side' do
      pts = methods.check_points([[0.25, -1], [0.5, 1], [0.5, 0], [0.75, 0]])
      expect(methods.drawn_value(pts, 0.375)).to eq(0)
      expect(methods.drawn_value(pts, 0.5)).to eq(0)
      expect(methods.drawn_value(pts, 0.5, side: :left)).to eq(1)
      # wrapping from the last point (0.75, 0) to the first (1.25, -1)
      expect(methods.drawn_value(pts, 1.0)).to eq(-0.5)
      expect(methods.drawn_value(pts, 0.1)).to be_within(1e-12).of(-0.7)
      expect(methods.drawn_value([[0.3, 0.4].freeze], 0.9)).to eq(0.4)
    end

    it 'raises for points out of range or out of order' do
      expect { 1.constant.tremolo(1, shape: [[0, -50], [1, 0]]) }.to raise_error(ArgumentError, /y from -1/)
      expect { 1.constant.tremolo(1, shape: [[0.5, 0], [0.2, 1]]) }.to raise_error(ArgumentError, /left to right/)
      expect { 1.constant.tremolo(1, shape: [[0, 0], [2, 1]]) }.to raise_error(ArgumentError, /x from 0 to 1/)
      expect { 1.constant.tremolo(1, shape: []) }.to raise_error(ArgumentError, /at least one/)
      expect { 1.constant.tremolo(1, shape: [[0, 1]], seam: 2) }.to raise_error(ArgumentError, /seam/)
    end

    it 'keeps one table per shape and seam' do
      a = methods.drawn_table([[0, 1], [1, -1]], seam: 0.1)
      expect(methods.drawn_table([[0, 1.0], [1, -1]], seam: 0.1)).to equal(a)
      expect(methods.drawn_table([[0, 1], [1, -1]])).not_to equal(a)
    end

    it 'takes seam: :auto, about 3 ms or 0.1 of a cycle where that is shorter, with a knee (effects-3)' do
      ms = ->(f) { methods.auto_seam(f) / f * 1000 }
      [1, 2, 4, 8].each { |f| expect(ms.(f)).to be_within(0.01).of(3) }
      expect(methods.auto_seam(33)).to be_between(0.08, 0.09) # the knee: 0.84 of either
      expect(methods.auto_seam(200)).to eq(0.1)
      expect(methods.auto_seam(1.n4)).to eq(methods.auto_seam(2)) # 120 BPM
      expect(methods.auto_seam(4.hz)).to eq(methods.auto_seam(4))
      expect(methods.auto_seam(0.25.seconds)).to eq(methods.auto_seam(4))
      expect(methods.auto_seam(3.constant)).to eq(0.1) # (a node rate: no fixed cycle)
      expect(methods.auto_seam(0.01) * methods::DRAWN_SIZE).to eq(2) # (at least two table steps)
      # the ramp at 2 Hz blends its wrap over 3 ms (144 samples) instead of 0.1 of a cycle (24 ms)
      a = take(1.constant.tremolo(2, depth: 24.db, shape: [[0, -1], [1, 1]], seam: :auto), 24000)[0]
      b = take(1.constant.tremolo(2, depth: 24.db, shape: [[0, -1], [1, 1]], seam: 0.006), 24000)[0]
      expect(a).to eq(b)
      expect(db(a[72])).to be_within(1e-3).of(-24 * (1 - 0.003)) # (the seam's end at x = 0.003: the shape's own value)
      expect(db(a[0])).to be_within(1e-3).of(-12) # (its middle)
    end

    it 'takes seam: true as :auto, a Length as that long, and a number as a fraction of a cycle (effects-4)' do
      ramp = [[0, -1], [1, 1]]
      mk = ->(rate, seam) { take(1.constant.tremolo(rate, depth: 24.db, shape: ramp, seam: seam), 12000)[0] }
      expect(mk.(2, true)).to eq(mk.(2, :auto))
      expect(mk.(25, true)).to eq(mk.(25, :auto))
      expect(mk.(2, 3.ms)).to eq(mk.(2, 0.006)) # 3 ms at 2 Hz: 0.006 of a cycle
      expect(mk.(1.n4, 3.ms)).to eq(mk.(2, 0.006)) # (a tempo rate at 120 BPM)
      expect(methods.seam_cycles(5.ms, 4)).to eq(0.02)
      expect(methods.seam_cycles(1.n64, 1.n4)).to eq(0.0625)
      expect(methods.seam_cycles(10.ms, 500)).to eq(1.0) # (at most a cycle)
      expect(methods.seam_cycles(0.ms, 4)).to be_nil
      expect(methods.seam_cycles(0.1, 4)).to eq(0.1)
      expect(methods.seam_cycles(false, 4)).to be_nil
      expect { 1.constant.tremolo(2.constant, shape: ramp, seam: 3.ms) }.to raise_error(ArgumentError, /fixed rate/)
      expect { 1.constant.tremolo(2, shape: ramp, seam: :wide) }.to raise_error(ArgumentError, /seam: is true or :auto/)
      expect(1.constant.tremolo(2, shape: ramp, seam: 3.ms).to_ruby).to include('seam: 3.ms')
    end
  end
end

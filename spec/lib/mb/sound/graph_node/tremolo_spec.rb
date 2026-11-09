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

    it 'follows the tempo for musical lengths' do
      MB::Sound.bpm(120)
      b = take(1.constant.tremolo(1.n4, depth: 0, law: :linear, shape: :triangle), 24000)[0]
      expect([b[0], b[6000], b[12000], b[18000]]).to eq([0.5, 1.0, 0.5, 0.0])
    ensure
      MB::Sound.rewind
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

    it 'blends the wrap over seam: of a cycle (Sony "blend graph edges": a tenth of a cycle)' do
      b = take(1.constant.tremolo(1, depth: 24.db, shape: [[0, -1], [1, 1]], seam: true), 48000)[0]
      # measured on Sony's render: -1.2 dB at 0.95, -22.8 dB at 0.05, a dB line between
      expect(db(b[45600])).to be_within(1e-3).of(-1.2)
      expect(db(b[2400])).to be_within(1e-3).of(-22.8)
      expect(db(b[0])).to be_within(1e-3).of(-12)
      expect(db(b[46800])).to be_within(1e-3).of(-6.6)
      expect(db(b[24000])).to be_within(1e-3).of(-12)
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
      a = methods.drawn_table([[0, 1], [1, -1]], seam: true)
      expect(methods.drawn_table([[0, 1.0], [1, -1]], seam: 0.1)).to equal(a)
      expect(methods.drawn_table([[0, 1], [1, -1]])).not_to equal(a)
    end
  end
end

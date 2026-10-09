RSpec.describe(MB::Sound::Unison, :aggregate_failures) do
  # Samples +node+ (or each channel of a bundle) +buffers+ times.
  def render(node, buffers: 10, buffer: 480)
    if node.channel_count > 1
      out = node.outputs.map { [] }
      buffers.times { node.outputs.each_with_index { |o, i| out[i] << o.sample(buffer).dup } }
      out.map { |l| l.reduce(:concatenate) }
    else
      buffers.times.map { node.sample(buffer).dup }.reduce(:concatenate)
    end
  end

  def rms(data)
    Math.sqrt((data.cast_to(Numo::DFloat) ** 2).mean)
  end

  # The unison mixer behind a node or bundle from Pitch#unison.
  def mixer(node)
    node.outputs.first.sources[:mixer]
  end

  describe '.offsets' do
    it 'spaces copies evenly with the outermost ones the detune away from the pitch' do
      expect(described_class.offsets(3, 10.cents, layout: :even)).to eq([-0.1, 0.0, 0.1])
      o = described_class.offsets(4, 0.3, layout: :even)
      expect(o.map { |v| v.round(12) }).to eq([-0.3, -0.1, 0.1, 0.3])
      expect(described_class.offsets(1, 10.cents)).to eq([0.0])
      expect(described_class.offsets(3, 0, layout: :random)).to eq([0.0, 0.0, 0.0])
    end

    it 'moves copies off the even layout randomly, centered and scaled back to the detune' do
      100.times do |seed|
        o = described_class.offsets(7, 20.cents, layout: :random, rng: Random.new(seed))
        expect(o.sum).to be_within(1e-12).of(0)
        expect(o.map(&:abs).max).to be_within(1e-12).of(0.2)
        expect(o).to eq(o.sort)
        expect(o.each_cons(2).map { |a, b| b - a }.min).to be > 0.2 / 3 * (1 - 2 * described_class::JITTER) * 0.5
      end

      a = described_class.offsets(7, 20.cents, rng: Random.new(1))
      expect(described_class.offsets(7, 20.cents, rng: Random.new(1))).to eq(a)
      expect(described_class.offsets(7, 20.cents, rng: Random.new(2))).not_to eq(a)
      expect(a).not_to eq(described_class.offsets(7, 20.cents, layout: :even))
    end

    it 'accepts an Array of offsets' do
      expect(described_class.offsets(3, [-5.cents, 0, 1.st])).to eq([-0.05, 0.0, 1.0])
      expect { described_class.offsets(2, [0, 1, 2]) }.to raise_error(ArgumentError, /2 detune offsets/)
    end

    it 'rejects bad arguments' do
      expect { described_class.offsets(0, 1) }.to raise_error(ArgumentError, /at least one/)
      expect { described_class.offsets(3, -1) }.to raise_error(ArgumentError, /negative/)
      expect { described_class.offsets(3, 1, layout: :wide) }.to raise_error(ArgumentError, /layout/)
    end
  end

  describe '.pan_slots' do
    it 'puts the copy nearest the pitch in the center and alternates sides by pair' do
      expect(described_class.pan_slots([-0.2, -0.1, 0, 0.1, 0.2])).to eq([-1.0, 0.5, 0.0, -0.5, 1.0])
      expect(described_class.pan_slots([0.3])).to eq([0.0])
      expect(described_class.pan_slots([-0.1, 0.1])).to eq([1.0, -1.0])
    end

    it 'spaces the slots evenly with copies above and below the pitch on each side' do
      [2, 3, 6, 7].each do |n|
        offsets = described_class.offsets(n, 25.cents, rng: Random.new(n))
        slots = described_class.pan_slots(offsets)
        expect(slots.sort.map { |s| s.round(12) }).to eq(Array.new(n) { |i| (-1 + 2.0 * i / (n - 1)).round(12) })
        next if n < 6

        left = offsets.select.with_index { |_, i| slots[i] < 0 }
        right = offsets.select.with_index { |_, i| slots[i] > 0 }
        [left, right].each do |side|
          expect(side.min).to be < 0
          expect(side.max).to be > 0
        end
      end
    end
  end

  describe 'Pitch#unison' do
    it 'calls the block with detuned pitches and the index' do
      seen = []
      220.hz.unison(3, detune: 10.cents, layout: :even) { |p, i| seen << [p, i]; p.saw }
      expect(seen.map(&:last)).to eq([0, 1, 2])
      expect(seen.map { |p, _| p.frequency }).to eq([-0.1, 0, 0.1].map { |st| 220 * 2 ** (st / 12) })
      expect(seen.map(&:first)).to all(be_constant)
    end

    it 'detunes Notes in the session tuning' do
      seen = []
      MB::Sound::A4.unison(2, detune: 50.cents, layout: :even) { |p| seen << p; p.saw }
      expect(seen).to all(be_a(MB::Sound::Note))
      expect(seen.map(&:frequency)).to match([be_within(1e-9).of(440 * 2 ** (-0.5 / 12)), be_within(1e-9).of(440 * 2 ** (0.5 / 12))])
    end

    it 'makes saws without a block, and accepts a Pitch from the block' do
      tones = []
      allow(MB::Sound::Unison).to receive(:apply_phase).and_wrap_original { |m, t, ph| tones << t; m.call(t, ph) }
      110.hz.unison(2)
      expect(tones.map(&:wave_type)).to eq([:ramp, :ramp])

      expect(rms(render(110.hz.unison(2, detune: 0, phase: 0, normalize: :peak) { |p| p }))).to be_within(1e-3).of(Math.sqrt(0.5))
    end

    it 'defaults to three copies, or one per detune offset' do
      expect(mixer(110.hz.unison).inputs.length).to eq(3)
      expect(mixer(110.hz.unison(detune: [0, 0.1])).inputs.length).to eq(2)
      expect(mixer(110.hz.unison(detune: [0, 0.1])).offsets).to eq([0, 0.1])
    end

    describe 'normalization' do
      let(:one) { render(110.hz.sine) }

      it 'scales copies in phase by 1/sqrt(n) (:power, default), 1/n (:peak), or a number' do
        mk = ->(**opts) { render(110.hz.unison(4, detune: 0, phase: 0, **opts) { |p| p.sine }) }
        expect(mk.call).to eq(one * 2)
        expect((mk.call(normalize: :peak) - one).abs.max).to be < 1e-6
        expect((mk.call(normalize: 1) - one * 4).abs.max).to be < 1e-5
      end

      it 'keeps the power of detuned copies about the same for any count' do
        levels = [1, 3, 7].map { |n| rms(render(110.hz.unison(n, detune: 30.cents) { |p| p.sine }, buffers: 200)) }
        expect(levels).to all(be_within(0.12).of(Math.sqrt(0.5)))
      end

      it 'rejects unknown laws' do
        expect { 110.hz.unison(normalize: :loud) }.to raise_error(ArgumentError, /normalize/)
      end
    end

    describe 'phase' do
      def tones_for(**opts, &block)
        tones = []
        block ||= ->(p, _i) { p.saw }
        110.hz.unison(3, **opts) { |p, i| block.call(p, i).tap { |t| tones << t } }
        tones
      end

      it 'gives every copy a random phase by default' do
        tones = tones_for
        expect(tones).to all(be_random_phase)
        expect(tones.map(&:seed).uniq.length).to eq(3)
      end

      it 'applies to every oscillator made in the block, keeping free and reset settings' do
        mods = []
        tones = tones_for { |p| mods << p.transpose(12).sine.at(100); p.saw.free.fm(mods.last) }
        expect(tones).to all(be_free)
        expect(tones).to all(be_random_phase)
        expect(mods).to all(be_random_phase)
      end

      it 'starts every copy at a number of cycles' do
        tones = tones_for(phase: 0.25)
        expect(tones.map(&:phase)).to eq([0.25] * 3)
        expect(tones.map(&:random_phase?)).to eq([false] * 3)
      end

      it 'leaves the block oscillators alone with :reset' do
        tones = tones_for(phase: :reset) { |p| p.saw.with_phase(1) }
        expect(tones.map(&:phase)).to eq([1] * 3)
        expect(tones.map(&:random_phase?)).to eq([false] * 3)
      end

      it 'rejects other values' do
        expect { 110.hz.unison(phase: :sometimes) }.to raise_error(ArgumentError, /phase/)
      end

      it 'does not change the original pitch' do
        p = 110.hz
        p.unison(3)
        expect(p.tone.random_phase?).to eq(false)
      end
    end

    describe 'seeds' do
      it 'repeats after the same root seed and changes with another' do
        mk = ->(seed) { MB::Sound.seed(seed); render(110.hz.unison(5, detune: 20.cents)) }
        a = mk.call(3)
        expect(mk.call(3)).to eq(a)
        expect(mk.call(4)).not_to eq(a)
      end

      it 'fixes the layout with seed:, while phases still come from the root generator' do
        MB::Sound.seed(1)
        a = mixer(110.hz.unison(5, detune: 20.cents, seed: 9))
        MB::Sound.seed(2)
        b = mixer(110.hz.unison(5, detune: 20.cents, seed: 9))
        expect(a.offsets).to eq(b.offsets)
        expect(a.offsets).to eq(described_class.offsets(5, 20.cents, rng: Random.new(9)))
        expect(a.inputs.map { |i| i.original_source.seed }).not_to eq(b.inputs.map { |i| i.original_source.seed })
      end
    end

    describe 'spread' do
      it 'returns one node without a spread, and a stereo bundle with one' do
        mono = 110.hz.unison(3)
        expect(mono.channel_count).to eq(1)
        expect(mixer(mono)).not_to be_stereo

        st = 110.hz.unison(3, spread: 0.5)
        expect(st).to be_a(MB::Sound::GraphNode::Channels)
        expect(st.channel_count).to eq(2)
        expect(mixer(st)).to be_stereo
      end

      it 'pans the copies to their slots times the spread, keeping the mono power in each channel' do
        m = mixer(110.hz.unison(5, detune: 20.cents, layout: :even, spread: 0.5))
        expect(m.slots).to eq([-1.0, 0.5, 0.0, -0.5, 1.0])
        left, right = m.gains
        g = 1 / Math.sqrt(5)
        expect(left[2]).to be_within(1e-12).of(g)
        expect(right[2]).to be_within(1e-12).of(g)
        m.slots.each_with_index do |s, i|
          pos = s * 0.5
          expect(left[i] ** 2 + right[i] ** 2).to be_within(1e-12).of(2 * g * g)
          expect(right[i] > left[i]).to eq(pos > 0) if pos != 0
          expect(right[i] / left[i]).to be_within(1e-12).of(Math.tan((pos + 1) * Math::PI / 4))
        end
      end

      it 'is about as loud in each channel as the mono version' do
        n = 7
        mk = ->(spread) { MB::Sound.seed(5); 110.hz.unison(n, detune: 25.cents, spread: spread) }
        mono = render(mk.call(0), buffers: 200)
        l, r = render(mk.call(1), buffers: 200)
        expect(rms(l)).to be_within(0.15 * rms(mono)).of(rms(mono))
        expect(rms(r)).to be_within(0.15 * rms(mono)).of(rms(mono))
        expect(l).not_to eq(r)
      end

      it 'takes a node' do
        st = 110.hz.unison(3, spread: 0.25.constant)
        l, r = render(st, buffers: 2)
        expect(l).not_to eq(r)
      end

      it 'rejects spreads outside 0..1' do
        expect { 110.hz.unison(spread: 2) }.to raise_error(ArgumentError, /spread/)
        expect { 110.hz.unison(spread: -0.1) }.to raise_error(ArgumentError, /spread/)
      end
    end

    it 'requires one channel per copy' do
      expect { 110.hz.unison(2) { |p| p.saw.pan(0) } }.to raise_error(ArgumentError, /one channel/)
      expect { 110.hz.unison(2) { |p| 3 } }.to raise_error(ArgumentError, /graph node/)
    end

    it 'works with pwm, pm, and reset in the block' do
      node = 110.hz.unison(3, detune: 10.cents) { |p| p.square.pwm(0.3).pm(p.transpose(7).sine.at(0.5)) }
      expect(render(node).abs.max).to be > 0.5

      trig = 4.hz.lfo.asquare.at(0..1)
      tones = []
      node = 110.hz.unison(2) { |p| p.saw.reset(trig).tap { |t| tones << t } }
      expect(tones.map(&:reset_input)).to all(be_truthy)
      expect(tones).to all(be_random_phase)
      expect(render(node).abs.max).to be > 0.5
    end
  end

  describe 'detune nodes' do
    # The Unison::Detune node behind a unison graph.
    def detune_node(node)
      node.graph.find { |n| n.is_a?(MB::Sound::Unison::Detune) }
    end

    # Samples every output of a Detune node +buffers+ times; returns one
    # DFloat of Hz per copy.
    def copy_freqs(det, buffers: 20, buffer: 480)
      out = det.outputs.map { [] }
      buffers.times { det.outputs.each_with_index { |o, i| out[i] << o.sample(buffer).cast_to(Numo::DFloat) } }
      out.map { |l| l.reduce(:concatenate) }
    end

    def cents(a, b)
      Numo::NMath.log2(a / b) * 1200
    end

    it 'leaves fixed detunes on plain transposed pitches (no Detune node)' do
      seen = []
      node = 110.hz.unison(3, detune: 10.cents, detune_mode: :exact) { |p| seen << p; p.saw }
      expect(detune_node(node)).to be_nil
      expect(seen.map(&:class)).to all(eq(MB::Sound::Pitch))
      expect(seen).to all(be_constant)
    end

    it 'gives the block copies at fixed fractions of the detune, scaled by the node' do
      seen = []
      node = 220.hz.unison(5, detune: 0.2.constant, layout: :even) { |p, i| seen << [p, i]; p.saw }
      expect(seen.map(&:last)).to eq([0, 1, 2, 3, 4])
      expect(seen.map(&:first)).to all(be_a(MB::Sound::Unison::CopyPitch))
      expect(seen.map(&:first)).not_to include(be_constant)

      det = detune_node(node)
      expect(det.fractions).to eq([-1, -0.5, 0, 0.5, 1])
      expect(det.mode).to eq(:exact)
      expect(mixer(node).slots).to eq(described_class.pan_slots(det.fractions))
      expect(mixer(node).offsets).to be_nil
      expect(render(node).abs.max).to be > 0.5
    end

    it 'takes the random layout from the seed, like fixed detunes' do
      a = detune_node(110.hz.unison(7, detune: 0.2.constant, seed: 3))
      expect(a.fractions).to eq(described_class.fractions(7, rng: Random.new(3)))
      expect(a.fractions.map(&:abs).max).to eq(1)
      expect(a.fractions.each_cons(2).all? { |x, y| x < y }).to eq(true)
      expect(described_class.fractions(7, rng: Random.new(3))).to eq(described_class.offsets(7, 1, rng: Random.new(3)))
    end

    it 'matches the exact formula per sample in :exact mode' do
      lfo = 3.hz.lfo.at(0..1)
      node = 110.hz.unison(7, detune: lfo, detune_mode: :exact, seed: 1)
      det = detune_node(node)
      expect(det.mode).to eq(:exact)
      freqs = copy_freqs(det)

      d = render(3.hz.lfo.at(0..1), buffers: 20).cast_to(Numo::DFloat)
      det.fractions.each_with_index do |a, i|
        expected = 110 * 2 ** (a * d / 12)
        expect(cents(freqs[i], expected).abs.max).to be < 1e-4
      end
    end

    [10, 25, 50, 100].each do |c|
      it "keeps :interp within the predicted error at #{c} cents (middle copy sharp by 1200 log2(cosh(x)))" do
        bound = 1200 * Math.log2(Math.cosh(c / 100.0 * Math.log(2) / 12))
        det = detune_node(110.hz.unison(7, detune: (c / 100.0).constant, layout: :even, detune_mode: :interp))
        freqs = copy_freqs(det, buffers: 2)
        errs = det.fractions.each_with_index.map { |a, i| cents(freqs[i], 110 * 2 ** (a * c / 1200.0)).abs.max }

        expect(errs[0]).to be < 1e-3
        expect(errs[6]).to be < 1e-3
        expect(errs.max).to be_within(1e-3).of(bound)
        expect(errs[3]).to eq(errs.max)
        expect(cents(freqs[3], 110.0 * Math.cosh(c / 100.0 * Math.log(2) / 12)).abs.max).to be < 1e-3
      end
    end

    it 'follows a moving detune in :interp mode with exact outer copies and the same bound' do
      lfo = -> { 0.5.hz.lfo.at(0..0.5) }
      ex = copy_freqs(detune_node(110.hz.unison(7, detune: lfo.call, detune_mode: :exact, layout: :even)), buffers: 50)
      it = copy_freqs(detune_node(110.hz.unison(7, detune: lfo.call, layout: :even, detune_mode: :interp)), buffers: 50)
      bound = 1200 * Math.log2(Math.cosh(0.5 * Math.log(2) / 12))
      # Outer copies only lag by the control interval (up to 78.5 cents/s × 16 samples)
      7.times do |i|
        expect(cents(it[i], ex[i]).abs.max).to be < ([0, 6].include?(i) ? 0.03 : bound + 0.03)
      end
    end

    it 'gives the same :interp output at any buffer size' do
      a = copy_freqs(detune_node(110.hz.unison(5, detune: 7.hz.lfo.at(0..0.5), layout: :even, detune_mode: :interp)), buffers: 20, buffer: 480)
      b = copy_freqs(detune_node(110.hz.unison(5, detune: 7.hz.lfo.at(0..0.5), layout: :even, detune_mode: :interp)), buffers: 75, buffer: 128)
      expect(b.map { |x| x[0...9600] }).to eq(a)
    end

    it 'ramps to detune steps over the control interval in :interp mode, and jumps in :exact mode' do
      step = -> { MB::Sound.silence(0.01).and_then(1.constant) }
      ex = copy_freqs(detune_node(110.hz.unison(3, detune: step.call, layout: :even, detune_mode: :exact)), buffers: 2)
      it = copy_freqs(detune_node(110.hz.unison(3, detune: step.call, layout: :even, detune_mode: :interp)), buffers: 2)
      r = 2 ** (1 / 12.0)
      expect(ex[2][479..481].to_a).to match([be_within(1e-4).of(110), be_within(1e-4).of(110 * r), be_within(1e-4).of(110 * r)])

      k = MB::Sound::Unison::Detune::DEFAULT_CONTROL
      expect(it[2][479]).to be_within(1e-4).of(110)
      # The step lands at sample 480 (a control point for 16 and 32), ramping over k samples
      expect(it[2][480 + k - 1]).to be_within(1e-4).of(110 * r)
      expect(it[2][480 + k / 2 - 1]).to be_within(1e-4).of(110 * (1 + (r - 1) / 2))
    end

    it 'uses scalar ratios for constant buffers, giving the same samples as the per-sample kernel' do
      det = detune_node(MB::Sound::Pitch.new(110.constant).unison(5, detune: 0.3.constant, detune_mode: :exact))
      expect(MB::Sound::FastUnison).to receive(:scale).at_least(:once).and_call_original
      expect(MB::Sound::FastUnison).not_to receive(:exact)
      freqs = copy_freqs(det, buffers: 3)

      out = Numo::SFloat.zeros(5, 480)
      MB::Sound::Unison::Detune::RubyKernel.exact(out, 110.0, Numo::SFloat.zeros(480).fill(0.3), det.fractions)
      5.times { |i| expect(freqs[i][-480..]).to eq(out[i, true].cast_to(Numo::DFloat)) }
    end

    it 'keeps the last frame for a constant pitch and detune' do
      [:exact, :interp].each do |mode|
        det = detune_node(110.hz.unison(3, detune: 0.3.constant, detune_mode: mode))
        copy_freqs(det, buffers: 2)
        expect(MB::Sound::FastUnison).not_to receive(:scale)
        expect(MB::Sound::FastUnison).not_to receive(:exact)
        expect(MB::Sound::FastUnison).not_to receive(:interp)
        copy_freqs(det, buffers: 3)
        RSpec::Mocks.space.reset_all
      end
    end

    it 'gives the same samples with the Ruby kernel' do
      [:exact, :interp].each do |mode|
        a = MB::Sound::Unison::Detune.new(220.hz.vibrato(5, depth: 0.2).freq, 2.hz.lfo.at(0..0.4), fractions: [-1, -0.3, 0.2, 1], mode: mode)
        b = MB::Sound::Unison::Detune.new(220.hz.vibrato(5, depth: 0.2).freq, 2.hz.lfo.at(0..0.4), fractions: [-1, -0.3, 0.2, 1], mode: mode, kernel: MB::Sound::Unison::Detune::RubyKernel)
        expect(copy_freqs(a, buffers: 5, buffer: 100)).to eq(copy_freqs(b, buffers: 5, buffer: 100))
      end
    end

    it 'keeps derived pitches on the detune' do
      seen = []
      node = 110.hz.unison(3, detune: 0.2.constant, layout: :even, detune_mode: :exact) { |p| seen << p.transpose(12); p.sine.fm(seen.last.sine.at(100)) }
      expect(seen).to all(be_a(MB::Sound::Unison::CopyPitch))
      expect(render(node, buffers: 2).abs.max).to be > 0.5
      up = seen[2].freq.sample(480)
      expect(up.cast_to(Numo::DFloat)).to be_within(1e-3).of(220 * 2 ** (0.2 / 12))
    end

    it 'has stereo spread with a detune node' do
      l, r = render(110.hz.unison(5, detune: 0.2.hz.lfo.at(0..0.3), spread: 1), buffers: 2)
      expect(l).not_to eq(r)
    end

    it 'rejects nodes in a detune Array, and unknown modes' do
      expect { 110.hz.unison(detune: [0.1.constant, 0, 0.1]) }.to raise_error(ArgumentError, /fixed offsets only/)
      expect { 110.hz.unison(detune: 0.1.constant, detune_mode: :fast) }.to raise_error(ArgumentError, /detune mode/)
      expect { 110.hz.unison(detune: 0.1, detune_mode: :fast) }.to raise_error(ArgumentError, /detune mode/)
    end
  end

  describe 'in Synth lanes' do
    let(:ev) { MB::Sound::MIDI::Event }
    let(:events) { [ev.note_on(48, 100), ev.note_on(55, 100, time: 0.05r), ev.note_off(48, time: 0.1r), ev.note_on(52, 100, time: 0.12r)] }

    def synth(seed: nil, unison_seed: nil, phase: :random)
      src = MIDIListSource.new(events, [ev.cc(99, 0, time: 1000r)])
      MB::Sound::Synth.new(src, voices: 2, spares: 0, seed: seed) { |v|
        v.hz.unison(3, detune: 15.cents, seed: unison_seed, phase: phase) * v.gate
      }
    end

    def render_synth(s)
      30.times.map { s.sample(480).dup }.reduce(:concatenate)
    end

    it 'keeps key sync, with random phases at each note' do
      tones = []
      allow(MB::Sound::Unison).to receive(:apply_phase).and_wrap_original { |m, t, ph| tones << t; m.call(t, ph) }
      synth
      expect(tones.length).to eq(6)
      expect(tones).to all(be_a(MB::Sound::Notes::KeyedTone))
      expect(tones).to all(be_key_sync)
      expect(tones).to all(be_random_phase)
    end

    it 'renders the same with the same synth seed, and gives each lane its own layout' do
      a = synth(seed: 4)
      b = synth(seed: 4)
      expect(render_synth(a)).to eq(render_synth(b))
      expect(render_synth(synth(seed: 5))).not_to eq(render_synth(synth(seed: 4)))

      offs = a.graph.select { |n| n.is_a?(MB::Sound::GraphNode::ChannelMixer::Unison) }.map(&:offsets)
      expect(offs.length).to eq(2)
      expect(offs.uniq.length).to eq(2)

      fixed = synth(seed: 4, unison_seed: 3).graph.select { |n| n.is_a?(MB::Sound::GraphNode::ChannelMixer::Unison) }.map(&:offsets)
      expect(fixed.uniq.length).to eq(1)
    end

    it 'takes a detune node from the voice, keeping key sync' do
      src = MIDIListSource.new([ev.cc(1, 0, time: 0r), ev.note_on(57, 100, time: 0r), ev.cc(1, 1.0, time: 0.05r)], [ev.cc(99, 0, time: 1000r)])
      tones = []
      allow(MB::Sound::Unison).to receive(:apply_phase).and_wrap_original { |m, t, ph| tones << t; m.call(t, ph) }
      s = MB::Sound::Synth.new(src, voices: 1, spares: 0) { |v| v.hz.unison(5, detune: v.mod * 0.5, layout: :even) * v.gate }
      expect(tones.length).to eq(5)
      expect(tones).to all(be_a(MB::Sound::Notes::KeyedTone))
      expect(tones).to all(be_key_sync)

      det = s.graph.find { |n| n.is_a?(MB::Sound::Unison::Detune) }
      out = render_synth(s)
      expect(out.abs.max).to be > 0.1

      # The wheel went from 0 to 1 at 0.05 s: the outer copies end 50 cents
      # from A3, the others at their exact fractions (:exact by default)
      expect(det.mode).to eq(:exact)
      expect(det.outputs.map(&:value)).to match([-1, -0.5, 0, 0.5, 1].map { |a| be_within(1e-3).of(220 * 2 ** (a * 0.5 / 12)) })
    end

    it 'restarts every copy at the same phase on each note with a fixed phase' do
      out = render_synth(synth(seed: 1, phase: 0))
      again = render_synth(synth(seed: 2, phase: 0))
      # Layouts differ between seeds, but every note starts at phase 0 in both
      start = out[0...20]
      expect(start.abs.max).to be > 0
      expect((again[0...20] - start).abs.max).to be < 0.05
    end
  end
end

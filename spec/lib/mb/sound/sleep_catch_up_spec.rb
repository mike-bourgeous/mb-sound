# Random streams under sleepers (delay-sleep-1; the maintainer's
# "Re-apply + catch-up", 2026-10-30): idle Synth lanes, sub-lanes, and drum
# voices that sleep move the random streams of their own nodes (noise,
# dust, drift, grains, shufflers: NodeTraits' +random+ trait) on by the
# frames they slept, so a voice that slept draws what it would have drawn
# awake, and the same voice renders the same samples with skipping on or
# off.
RSpec.describe('Sleeper random catch-up', :aggregate_failures) do
  let(:m) { MB::Sound }

  # A notes rhythm with gaps long enough for idle lanes to sleep (one
  # silent cell of the 800-sample grid after their envelopes end).
  let(:riff) { m.seq(m::C4, m::R, m::R, m::E4, m::R, m::R, m::R, m::G4).n8.loop }

  def env(v)
    v.amp_env(0.001, 0.05, 0, 0.02)
  end

  # The voices of the sweep below: one per catch-up kind (the guard at the
  # end checks every class with a catch-up method has one).  Each is gated
  # by its envelope directly, so skipping changes nothing at all.
  def self.voices
    {
      'MB::Sound::Tone' => ->(m, v, e) { (m.noise * e) + m.drift(5) * e * 0.1 }, # (a drift so the lane isn't fusable: fused lanes never sleep)
      'MB::Sound::GraphNode::Dust' => ->(m, v, e) { m.dust(3000, min_gap: 0.5.ms) * e },
      'MB::Sound::GraphNode::Drift' => ->(m, v, e) { m.drift(30, jitter: 0.5, hold: 0.2) * e },
      'MB::Sound::GraphNode::Grains' => ->(m, v, e) {
        smp = m::Sample[Numo::SFloat.cast(Array.new(6000) { |i| Math.sin(i * 0.03) * (1 + 0.3 * Math.sin(i * 0.0011)) })]
        smp.grains(density: 300, size: 0.01, position: 0.4, spread: 0.3, pitch_spread: 3, jitter: 1).mono * e
      },
      'MB::Sound::GraphNode::DataShuffler' => ->(m, v, e) {
        clips = [Numo::SFloat.cast(Array.new(300) { |i| Math.sin(i * 0.1) }), Numo::SFloat.cast(Array.new(500) { |i| Math.sin(i * 0.02) })]
        m::GraphNode::DataShuffler.new(clips, seed: 3) * e
      },
    }
  end

  def render_synth(skip, frames: 48_000, size: 800, &voice)
    m.seed(5)
    synth = m::Synth.new(riff.notes, voices: 2, skip_idle: skip, &voice)
    slept = 0
    bufs = []
    n = 0
    while n < frames
      c = [size, frames - n].min
      bufs << synth.sample(c).dup
      slept += synth.skipped_lanes.length
      n += c
    end
    [SpecBuffers.join(bufs), slept]
  ensure
    m.rewind
  end

  def expect_same(ref, got, label)
    diff = (ref - got).ne(0).where.to_a
    expect(diff.first(3)).to eq([]), "#{label}: #{diff.length} samples differ, max #{(ref - got).abs.max}"
  end

  describe 'Synth lanes' do
    voices.each do |klass, voice|
      it "renders a sleeping lane with #{klass.split('::').last} as if it never slept" do
        m = self.m
        ref, awake = render_synth(false) { |v| voice.call(m, v, env(v)) }
        got, slept = render_synth(true) { |v| voice.call(m, v, env(v)) }
        expect(awake).to eq(0)
        expect(slept).to be > 20
        expect(ref.abs.max).to be > 0.01
        expect_same(ref, got, klass)
      end
    end

    it 'catches up the same at any buffer size' do
      m = self.m
      voice = ->(v, _i = nil) { m.noise * env(v) + m.dust(500) * env(v) + m.drift(9) * env(v) * 0.1 }
      ref, = render_synth(false, &voice)
      [[367], [64], [1001]].each do |(size)|
        got, slept = render_synth(true, size: size, &voice)
        expect(slept).to be > 0
        expect_same(ref, got, "#{size}-sample buffers")
      end
    end

    it 'keeps noise whose frequency holds still in step (a voice of noise at its note frequency)' do
      m = self.m
      voice = ->(v, _i = nil) { v.hz.tone.ramp.noise(0.3) * env(v) + m.drift(5) * env(v) * 0.1 }
      ref, = render_synth(false, &voice)
      got, slept = render_synth(true, &voice)
      expect(slept).to be > 20
      expect_same(ref, got, 'note-frequency noise')
    end

    it 'catches a sleeping lane up before Session::Carry copies its states' do
      m = self.m
      m.seed(5)
      synth = m::Synth.new(riff.notes, voices: 2) { |v| m.noise * env(v) + m.drift(5) * env(v) * 0.1 }
      m.seed(5)
      awake = m::Synth.new(riff.notes, voices: 2, skip_idle: false) { |v| m.noise * env(v) + m.drift(5) * env(v) * 0.1 }
      tone = ->(s) { s.instance_variable_get(:@lane_graphs)[1].find { |n| n.is_a?(m::Tone) && m::NodeTraits.of(n).catch_up } }
      # (the second lane sleeps from its first silent cell on)
      until synth.skipped_lanes.include?(1) && synth.instance_variable_get(:@slept)[1] > 0
        synth.sample(800)
        awake.sample(800)
      end
      expect(tone.(synth).state.noise).not_to eq(tone.(awake).state.noise)
      synth.catch_up_sleepers
      expect(tone.(synth).state.noise).to eq(tone.(awake).state.noise)
      expect(tone.(synth).state.phase[0]).to eq(tone.(awake).state.phase[0])
    end
  end

  describe 'drum voices' do
    def render_kit(skip)
      m.seed(7)
      k = m.kit(m.grid(16, kick: 'x.......', snare: '....x...').loop, skip_idle: skip) { |b|
        b.voice(:kick) { |h| h.noise(decay: 0.05) } # (noise under its envelope: a body's resonator would keep a residue below -180 dB)
        b.voice(:snare) { |h| m.dust(2000) * h.env(0.05) }
      }
      SpecBuffers.join(60.times.map { k.sample(800).dup })
    ensure
      m.rewind
    end

    it 'renders a sleeping voice with noise and dust as if it never slept' do
      ref = render_kit(false)
      got = render_kit(true)
      expect(ref.abs.max).to be > 0.01
      expect_same(ref, got, 'kit')
    end

    # delay-sleep-2: a kit bounced into a Sample (as jungle.rb's record,
    # saved in presets/jungle_breaks.mbg) catches up as the same kit
    # sampled directly does, so a preset's bounced asset and its script
    # agree (save_presets_spec failed only because the asset was saved
    # before the catch-up)
    it 'catches a kit up the same inside a bounce as sampled directly' do
      make = -> { m.tr808(m.grid(16, kick: 'X...x...', snare: '....X..x', hat: 'x.x.x.x.'), snare: { snappy: 0.75 }, seed: 5) }
      m.seed(1)
      bounced = m.bounce(2.bars, bpm: 140) { make.() }.data
      m.seed(1)
      old = m.bpm
      m.bpm(140)
      kit = make.()
      direct = SpecBuffers.join(Array.new((bounced.length / 800.0).ceil) { kit.sample(800).dup })[0...bounced.length]
      expect(kit.voices.values.any? { |v| (cu = v.instance_variable_get(:@catch_ups)) && !cu.empty? }).to eq(true) # (a voice slept and caught noise up)
      expect_same(bounced, direct, 'bounced kit')
    ensure
      m.bpm(old) if old
    end
  end

  describe 'sub-lanes' do
    def render_sub(sub)
      old = m::Synth.sub_lanes
      m::Synth.sub_lanes = sub
      m.seed(9)
      mm = m
      clip = (m.seq(m::C3, m::A4, m::E3, m::Cs5).n8 & m.seq(m::G2, nil, m::B4, nil).n4).loop
      synth = clip.synth(voices: 2) { |v|
        # (a layer sounding above E4 only, like a sampler layer's zone; the
        # lane's own part is a drift, which keeps the lane unfused but
        # pauses nothing a key-synced oscillator would)
        zone = (v.number - 66).aclip(0, 1)
        high = mm::GraphNode::SubLane.new((mm.noise + mm.dust(800)) * env(v) * zone, notes: v, wake: ->(e) { e.note.to_i > 66 }, name: 'high')
        mm.drift(3) * env(v) * 0.1 + high.outputs[0]
      }
      out = SpecBuffers.join(60.times.map { synth.sample(800).dup })
      [out, synth.sub_lanes.flatten.sum(&:skipped_samples)]
    ensure
      m::Synth.sub_lanes = old
      m.rewind
    end

    it 'renders a sub-lane that slept as if it never had' do
      ref, = render_sub(false)
      got, skipped = render_sub(true)
      expect(skipped).to be > 0
      expect_same(ref, got, 'sub-lane')
    end
  end

  describe 'kernel' do
    it 'moves noise on exactly as rendering it would, in C and the Ruby mirror (Kernels.noise_skip)' do
      make = -> { m.seed(3); 2000.hz.ramp.noise }
      a = make.()
      a.sample(300)
      a.sample(4000)
      ref = a.sample(200).dup
      [:c, :ruby, :check].each do |mode|
        b = make.()
        b.sample(300)
        m::Kernels.with(mode) { b.catch_up_noise(4000) }
        expect_same(ref, b.sample(200).dup, "#{mode} kernel")
      end
    end
  end

  it 'has a sleep sweep voice for every class that catches up random streams' do
    LibraryFiles.require_all
    g = m::GraphNode
    kinds = ObjectSpace.each_object(Class).select { |c|
      c.name&.start_with?('MB::Sound::') && (c.include?(g) || c.include?(g::MultiOutput)) && m::NodeTraits.declaration(c)&.dig(:random).is_a?(Symbol) &&
        m::NodeTraits.for_class(c).catch_up
    }.map(&:name)
    # (Tone's catch-up is per instance: noise tones)
    expect((kinds + ['MB::Sound::Tone']).uniq.sort - self.class.voices.keys).to eq([])
  end
end

# Same samples at any buffer size (takes and renders promise this): drum
# machine voices, Synths that skip idle lanes, and naive oscillator edges
# landing exactly on samples.  Each case renders at 800-sample buffers
# (the usual size) and compares other sizes sample for sample, including
# odd alternating sizes (367/368, which put every edge somewhere new) and
# one-sample buffers.
RSpec.describe 'Buffer size invariance' do
  SIZES = [[367, 368], [64], [1031]].freeze

  # Renders the node from +make+ for +seconds+ in buffers cycling through
  # +sizes+ (seeded and rewound, so every render builds the same graph).
  def render_sizes(make, sizes, seconds)
    MB::Sound.rewind
    MB::Sound.seed(1)
    node = make.call
    total = (seconds * 48000).round
    out = nil
    n = 0
    i = 0
    while n < total
      c = [sizes[i % sizes.length], total - n].min
      b = node.sample(c)
      break if b.nil?

      out ||= b.class.zeros(total)
      out[n...(n + b.length)] = b
      n += c
      i += 1
    end
    [out, node]
  ensure
    MB::Sound.rewind
  end

  # Expects the same samples at every size in +sizes+ as at 800.
  def expect_invariant(make, seconds: 2.1, sizes: SIZES, tolerance: 0)
    ref, node = render_sizes(make, [800], seconds)
    expect(ref.abs.max).to be > 0.01
    sizes.each do |s|
      out, _ = render_sizes(make, s, seconds)
      r = ref[0...out.length]
      if tolerance == 0
        diff = (out - r).ne(0).where.to_a
        expect(diff.first(5)).to eq([]), "at buffer sizes #{s}: #{diff.length} samples differ from 800, first #{diff.first.inspect}"
      else
        expect((out - r).abs.max).to be <= tolerance * r.abs.max, "at buffer sizes #{s}"
      end
    end
    node
  end

  describe 'naive oscillators' do
    # 800 Hz is a 60-sample period and 540 Hz a jump every 800 samples:
    # phases accumulated with different rounding at different block sizes
    # used to put the jumps one sample apart (full-scale differences)
    [800, 540, 1000, 12_000].each do |f|
      it "asquare and pwm'd asquare at #{f} Hz land their jumps on the same samples" do
        expect_invariant(-> { f.hz.asquare }, seconds: 0.5)
        expect_invariant(-> { f.hz.asquare.pwm(0.25) }, seconds: 0.5)
      end

      it "aramp and gauss at #{f} Hz stay within -150 dB" do
        expect_invariant(-> { f.hz.aramp }, seconds: 0.5, tolerance: -150.db)
        expect_invariant(-> { f.hz.gauss }, seconds: 0.5, tolerance: -150.db)
      end
    end

    it 'snaps the naive shapes onto their jumps in the Ruby mirror too' do
      phases = Numo::DFloat[0.5 - 1e-12, 0.5, 1 - 1e-12, 0.25, 0.75]
      expect(MB::Sound::Tone.shape_ruby(:square, phases, 0, nil).to_a).to eq([-1, -1, 1, 1, -1])
      expect(MB::Sound::Tone.shape_ruby(:ramp, phases, 0, nil)[0..1].to_a).to eq([-1, -1])
      expect(MB::Sound::Tone.radians_value_ruby(:square, (0.5 - 1e-12) * 2 * Math::PI)).to eq(-1)
      expect(MB::Sound::Tone.radians_value_ruby(:square, (1 - 1e-12) * 2 * Math::PI)).to eq(1)
      expect(MB::FastSound.osc(:square, (0.5 - 1e-12) * 2 * Math::PI)).to eq(-1)
      expect(MB::FastSound.osc(:square, (1 - 1e-12) * 2 * Math::PI)).to eq(1)
    end
  end

  describe 'resonators' do
    it 'ring out to the same sample at any buffer size once their input ends' do
      # A sum ends with its first input to end: the shorter ring cuts the
      # longer one off on the exact sample where it falls below -120 dB
      make = -> {
        hit = MB::Sound.seq(MB::Sound::D2).n4.notes.trigger
        hit.ping(330, decay: 0.3) + hit.ping(110, decay: 2)
      }
      lengths = [[800], [367, 368], [64], [1031]].map { |s|
        MB::Sound.rewind
        node = make.call
        n = 0
        i = 0
        loop do
          b = node.sample(s[i % s.length])
          break if b.nil?
          n += b.length
          i += 1
        end
        n
      }
      expect(lengths.uniq.length).to eq(1)
      expect(lengths[0] % 800).not_to eq(0)
      expect_invariant(make, seconds: 0.8)
    ensure
      MB::Sound.rewind
    end
  end

  # fixes-12: a Notes gate or trigger without envelopes ended at the first
  # buffer start after the clip's last event, so a filter ringing on it
  # was cut 0..799 samples later depending on the buffer size (a 50 Hz
  # lowpass on a gate at full level).  They now end on their 800-sample
  # grid, where 800-sample buffers ended them before.
  describe 'Notes gates and triggers without envelopes' do
    # Total samples before the node from +make+ ends, at each size.
    def lengths(make, sizes)
      sizes.map { |s|
        MB::Sound.rewind
        node = make.call
        n = 0
        i = 0
        loop do
          b = node.sample(s[i % s.length])
          break if b.nil?

          n += b.length
          break if b.length < s[i % s.length]

          i += 1
        end
        n
      }
    ensure
      MB::Sound.rewind
    end

    {
      'a gate into a lowpass' => -> { MB::Sound.seq(MB::Sound::C4).n4.notes.gate.filter(:lowpass, cutoff: 50) },
      'a trigger into a bandpass' => -> { MB::Sound.seq(MB::Sound::D2, MB::Sound::A2).n8.notes.trigger.filter(:bandpass, cutoff: 200, quality: 20) * 100 },
      'a saw times a gate' => -> { n = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.notes; n.hz.saw * n.gate },
    }.each do |what, make|
      it "ends #{what} on the same sample at any buffer size" do
        sizes = [[800], [367, 368], [64], [1031], [1]]
        expect(lengths(make, sizes)).to eq([24_800] * sizes.length) # clip end 24000 (1/4 at 120 bpm)
        expect_invariant(make, seconds: 0.6, sizes: [[367, 368], [64], [1031], [7]])
      end
    end

    it 'keeps a graph going through a seek back before its end' do
      make = -> { n = MB::Sound.seq(MB::Sound::C4).n4.notes; [n, n.gate.filter(:lowpass, cutoff: 50)] }
      [[800], [367, 368]].each do |s|
        MB::Sound.rewind
        notes, node = make.call
        n = 0
        i = 0
        while n < 24_400
          c = s[i % s.length]
          expect(node.sample(c)&.length).to eq(c)
          n += c
          i += 1
        end
        notes.stream.seek(0)
        expect(node.sample(800)&.length).to eq(800)
      ensure
        MB::Sound.rewind
      end
    end
  end

  # fixes-13: graphs with Notes envelopes ended at the first buffer start
  # where every envelope was idle, and Synths at the first buffer start
  # after their lanes, so a resonant filter after them was cut -52 to -99
  # dB down, up to 800 samples earlier (or 1031 later).  They now end on
  # their 800-sample grid, where 800-sample buffers ended them before.
  describe 'Notes envelopes and Synths' do
    # Every sample of the node from +make+ until it ends (nil or a short
    # buffer), in buffers cycling through +sizes+.
    def until_end(make, sizes)
      MB::Sound.rewind
      MB::Sound.seed(1)
      node = make.call
      out = []
      i = 0
      loop do
        c = sizes[i % sizes.length]
        b = node.sample(c)
        break if b.nil?

        out << b.dup
        break if b.length < c

        i += 1
      end
      out.reduce(:concatenate)
    ensure
      MB::Sound.rewind
    end

    lp = ->(n) { n.filter(:lowpass, cutoff: 800, quality: 8) }
    {
      'a saw times an envelope into a resonant lowpass' => [27_200, -> {
        n = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.notes
        lp.(n.hz.saw * n.amp_env(0.01, 0.1, 0.5, 0.05))
      }],
      'two envelopes (amp and filter) of one Notes' => [39_200, -> {
        n = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.notes
        (n.hz.saw * n.amp_env(0.01, 0.1, 0.5, 0.3)).filter(:lowpass, cutoff: 200 + 2000 * n.filter_env(0.01, 0.05, 0.2, 0.02), quality: 8)
      }],
      'a Synth into a resonant lowpass' => [39_200, -> {
        lp.(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.synth(voices: 4) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05) })
      }],
      'a Synth with resonant filters in its lanes' => [44_800, -> {
        lp.(MB::Sound.seq(MB::Sound::C3, MB::Sound::E4, MB::Sound::G4).n8.synth(voices: 4) { |v|
          (v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05)).filter(:lowpass, cutoff: 300, quality: 20)
        })
      }],
      'a Synth with a 1 s tail' => [75_200, -> {
        lp.(MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8, voices: 2, tail: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05) })
      }],
    }.each do |what, (length, make)|
      it "ends #{what} on the same sample at any buffer size" do
        ref = until_end(make, [800])
        expect(ref.length).to eq(length)
        [[367, 368], [64], [1031], [1]].each do |s|
          out = until_end(make, s)
          expect(out.length).to eq(length), "at buffer sizes #{s}"
          # (planned :fast sines differ within -100 dB at other block sizes)
          expect((out - ref).abs.max).to be <= 1e-5 * ref.abs.max, "at buffer sizes #{s}"
        end
      end
    end
  end

  describe 'sampler' do
    let(:rec) { MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(48000).seq.map { |i| Math.sin(i * 0.03) * Math.exp(-(i % 6000) / 2000.0) })] }

    it 'gives the same chop samples at any buffer size (one truncating voice, declick tails, reverse, pitch)' do
      brk = rec.slices(16)
      expect_invariant(-> { brk.chop(0, 3, [5, 2], MB::Sound::Tie, brk[7].rev, 1, MB::Sound::Rest, [2, -3]).loop.sampler(brk) }, sizes: [[367, 368], [64], [1031], [1]])
    end

    it 'gives the same samples for looping polyphonic voices with bends' do
      s = rec[0...12_000].looped(2000...9000, mode: :ping_pong)
      clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4.n4).n8.loop
      expect_invariant(-> { clip.synth(voices: 3) { |v| s.play(v) * v.env(0.001, 0.1, 0.7, 0.05) } })
    end
  end

  describe 'tr808' do
    grid = ->(row) { MB::Sound.grid(16, row => 'x.......x....x..').loop }

    (MB::Sound::Drums::TR808::VOICES.keys - [:clap]).each do |v|
      it "gives the same #{v} samples at any buffer size (skipping it while idle)" do
        voice = expect_invariant(-> { MB::Sound.tr808(grid.(v)) })
        expect(voice[v].skippable?).to eq(true)
      end
    end

    [{ tune: 220, snappy: 0.8 }, { tone: 0.9, decay: 0.5 }, { snappy: 0, tune: 150 }, { level: 2, decay: 0.05 }].each do |knobs|
      it "gives the same snare samples with #{knobs}" do
        expect_invariant(-> { MB::Sound.tr808(MB::Sound.grid(16, snare: 'x...x..x....x.x.').loop, snare: knobs) }, sizes: [[367, 368], [64]])
      end
    end

    kit = { kick: 'x...x...x...x...', snare: '....x.......x...', closed_hat: 'x.x.x.x.x.x.x.x.', open_hat: '..............x.',
            cymbal: 'x...............', cowbell: '....x..x....x...', clap: '............x...', maracas: '.x.x.x.x.x.x.x.x',
            rimshot: '..x.....', claves: '.......x', low_tom: '......x.', high_conga: '.....x..' }

    it 'gives the same kit samples at any buffer size (shared metal bank, open hat choke)' do
      expect_invariant(-> { MB::Sound.tr808(MB::Sound.grid(16, **kit).loop) }, seconds: 2.1)
    end

    it 'gives the same kit samples with knobs and more cowbell' do
      expect_invariant(
        -> { MB::Sound.tr808(MB::Sound.grid(16, **kit).loop, closed_hat: { tune: 300, decay: 0.1 }, cowbell: { tune: 800 }, cymbal: { tone: 0.8 }, more_cowbell: true) },
        seconds: 4.5, sizes: [[367, 368], [64]]
      )
    end

    it 'gives the same separate outputs at any buffer size' do
      expect_invariant(-> { MB::Sound.tr808(MB::Sound.grid(16, **kit).loop, outputs: :separate)[:open_hat] }, seconds: 4.5, sizes: [[367, 368], [64]])
    end

    it 'gives the same samples for a MIDI file' do
      expect_invariant(-> { MB::Sound.tr808('spec/test_data/drums.mid') }, seconds: 2, sizes: [[367, 368], [64]]) if File.exist?('spec/test_data/drums.mid')
    end

    it 'gives the same samples with one-sample buffers (sleeping and waking on exact samples)' do
      old = MB::Sound.bpm
      MB::Sound.bpm(480) # hits 12000 and 19500 samples in, with sleeps between
      fast = { closed_hat: 'x.......x....x..', snare: '..x.........x...' }
      expect_invariant(-> { MB::Sound.tr808(MB::Sound.grid(16, **fast).loop) }, seconds: 0.42, sizes: [[1]])
      expect_invariant(-> { MB::Sound::Drums::TR808.cowbell(MB::Sound.grid(16, '........x....x..').loop) }, seconds: 0.42, sizes: [[1]])
    ensure
      MB::Sound.bpm(old)
    end

    it 'falls asleep on the 800-sample grid and wakes on the hit sample' do
      voice = MB::Sound::Drums::TR808.closed_hat(MB::Sound.grid(4, 'x...').loop)
      asleep = []
      2400.times { |i| voice.sample(20); asleep << i * 20 + 20 if voice.sleeping? && asleep.empty? }
      # 0.06 s decay: silent cells end at a multiple of 800 samples
      expect(asleep.first % 800).to eq(0)
    ensure
      MB::Sound.rewind
    end
  end

  # A tone whose frequency is a signal keeps a running phase wrapped every
  # sample (mb_phase.h; fixes-6), so it gives the same samples at any block
  # size, in every kernel and in plans (fixes-3 measured -138 to -145 dB
  # differences when each block summed its increments from its start).
  describe 'tones with a frequency signal' do
    fm = -> { 220.hz.fm(5.5.hz.lfo.at(12)) }
    cycle = -> { MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25, 0.125], size: 256) }
    sound = -> { Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) } }
    tones = {
      'naive sine' => -> { fm.().sine },
      'naive ramp' => -> { fm.().aramp },
      'phasor' => -> { fm.().phasor },
      'PolyBLEP saw' => -> { fm.().saw },
      'PolyBLEP square, pwm' => -> { fm.().square.pwm(0.3) },
      # A width or pivot signal moves the edges every sample: the first
      # sample of a buffer is corrected for the previous sample's warp, as
      # within a buffer (fixes-7; up to full scale at one-sample buffers)
      'PolyBLEP square, pwm signal' => -> { fm.().square.pwm(3.hz.lfo.at(0.2..0.8)) },
      'PolyBLEP saw, pwm signal' => -> { fm.().saw.pwm(0.5.hz.lfo.at(0.1..0.9)) },
      'PolyBLEP triangle, skew signal' => -> { fm.().triangle.skew(2.hz.lfo.at(0.2..0.8)) },
      'PolyBLEP square, pivot signal' => -> { fm.().square.pwm(0.3, pivot: 1.5.hz.lfo.at(0..0.5)) },
      'cycle wavetable, pwm signal' => -> { fm.().wavetable(cycle.()).pwm(3.hz.lfo.at(0.2..0.8)) },
      'BLIT complex ramp' => -> { fm.().complex_ramp },
      'feedback sine' => -> { fm.().sine.fm_feedback(0.2) },
      'cycle wavetable' => -> { fm.().wavetable(cycle.()) },
      'sample wavetable (looped)' => -> { fm.().wavetable(MB::Sound::Wavetable.from_samples(sound.(), mode: :sample, root: 200, loop: 1000...4000)) },
      'audio-rate FM' => -> { 220.hz.fm(330.hz.at(500)).saw },
    }

    it 'wraps phases to 0...1, never 1.0, and non-finite phases to 0 (Tone.wrap_phase, the mirror of mb_wrap_phase)' do
      w = MB::Sound::Tone
      expect(w.wrap_phase(0.25)).to eq(0.25)
      expect(w.wrap_phase(1.0)).to eq(0.0)
      expect(w.wrap_phase(1.75)).to eq(0.75)
      expect(w.wrap_phase(-0.25)).to eq(0.75)
      expect(w.wrap_phase(-1e-20)).to eq(0.0) # x - floor(x) rounds to 1.0
      expect(w.wrap_phase(7.5)).to eq(0.5)
      expect(w.wrap_phase(-3.25)).to eq(0.75)
      expect(w.wrap_phase(Float::NAN)).to eq(0.0)
      expect(w.wrap_phase(-Float::INFINITY)).to eq(0.0)
    end

    # Steps of more than a cycle per sample take mb_wrap_phase's floor()
    # path; within a cycle, its compares
    {
      'naive sine' => ->(f) { f.tone.sine },
      'PolyBLEP saw' => ->(f) { f.tone.saw },
      'PolyBLEP square with a width signal' => ->(f) { f.tone.square.pwm(MB::Sound.noise.at(0.1..0.9)) },
      'BLIT complex ramp' => ->(f) { f.tone.complex_ramp },
      'cycle wavetable' => ->(f) { f.tone.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5], size: 64)) },
    }.each do |name, make|
      it "gives the Ruby mirror's samples for a #{name} with wild frequencies" do
        tones = [:sample_c, :sample_ruby].map { |m|
          MB::Sound.seed(5)
          [m, make.(MB::Sound.noise.at(150_000) + 300.hz.at(400))]
        }
        [128, 37, 800].each do |n|
          a, b = tones.map { |m, t| t.public_send(m, n).dup }
          expect(b.to_a).to eq(a.to_a)
        end
      end
    end

    [false, true].each do |planned|
      tones.each do |name, make|
        it "gives the same samples at any buffer size for a #{name} (#{planned ? 'planned' : 'unplanned'})" do
          build = -> {
            g = make.() * 0.5
            MB::Sound::Plan.install(g) if planned
            g
          }
          expect_invariant(build, seconds: 0.7, sizes: [[367, 368], [1], [1031]])
        end
      end
    end
  end

  # A tone with a constant frequency computes its phases from the last
  # point of an 800-sample grid of its own time (mb_phase.h; fixes-7), so it
  # gives the same samples at any block size (before, from each block's
  # start: a 3.3 Hz phasor's wraps a sample apart at 367/368, a persona
  # take's 31.1-second loop strikes -130 dB)
  describe 'tones with a constant frequency' do
    cycle = -> { MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25, 0.125], size: 256) }
    sound = -> { Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) } }
    tones = {
      'naive sine' => -> { 220.3.hz.sine },
      'naive ramp' => -> { 220.3.hz.aramp },
      'phasor' => -> { 3.3.hz.phasor },
      'LFO' => -> { 0.31.hz.lfo },
      'PolyBLEP saw' => -> { 220.3.hz.saw },
      'PolyBLEP square, pwm signal' => -> { 220.3.hz.square.pwm(3.hz.lfo.at(0.2..0.8)) },
      'BLIT complex ramp' => -> { 220.3.hz.complex_ramp },
      'feedback sine' => -> { 220.3.hz.sine.fm_feedback(0.2) },
      'cycle wavetable' => -> { 220.3.hz.wavetable(cycle.()) },
      'cycle wavetable, pwm signal' => -> { 220.3.hz.wavetable(cycle.()).pwm(3.hz.lfo.at(0.2..0.8)) },
      'sample wavetable (looped)' => -> { 220.3.hz.wavetable(MB::Sound::Wavetable.from_samples(sound.(), mode: :sample, root: 200, loop: 1000...4000)) },
      'wraps port' => -> { (1.0 / 0.311).hz.lfo.with_phase(0.93).wraps.ping(400, decay: 0.2) },
    }

    [false, true].each do |planned|
      tones.each do |name, make|
        it "gives the same samples at any buffer size for a #{name} (#{planned ? 'planned' : 'unplanned'})" do
          build = -> {
            g = make.() * 0.5
            MB::Sound::Plan.install(g) if planned
            g
          }
          expect_invariant(build, seconds: 0.7, sizes: [[367, 368], [1], [1031]])
        end
      end
    end

    {
      'naive sine' => -> { 220.3.hz.sine },
      'PolyBLEP square' => -> { 220.3.hz.square.pwm(0.3) },
      'BLIT complex ramp' => -> { 220.3.hz.complex_ramp },
      'cycle wavetable' => -> { 220.3.hz.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5], size: 64)) },
      'feedback sine' => -> { 220.3.hz.sine.fm_feedback(0.3) },
      'cycle wavetable, width signal' => -> { 220.3.hz.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25], size: 64)).pwm(MB::Sound.noise.at(0.1..0.9)) },
      'sample wavetable (looped)' => -> {
        s = Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) }
        220.3.hz.wavetable(MB::Sound::Wavetable.from_samples(s, mode: :sample, root: 200, loop: 1000...4000))
      },
    }.each do |name, make|
      it "gives the Ruby mirror's samples and state for a #{name} across grid points" do
        tones = [:sample_c, :sample_ruby].map { |m|
          MB::Sound.seed(5)
          [m, make.()]
        }
        [367, 1, 1031, 800, 433].each do |n|
          a, b = tones.map { |m, t| t.public_send(m, n).dup }
          expect(b.to_a).to eq(a.to_a)
          expect(tones[1][1].state.phase).to eq(tones[0][1].state.phase)
          expect(tones[1][1].state.table).to eq(tones[0][1].state.table)
        end
      end
    end
  end

  # Filters flush states below 1e-30 on an 800-sample grid of their own
  # time (MB_FLUSH_GRID; fixes-7: after each buffer before, so tails below
  # 1e-30 differed by buffer size)
  describe 'filter state flushing' do
    tiny = -> { MB::Sound::GraphNode::Constant.new(1e-31, sample_rate: 48000) }
    {
      'SVF' => -> { tiny.().filter(:lowpass, cutoff: 500, quality: 0.7) },
      'four-pole' => -> { tiny.().lp4(500, resonance: 0.3) },
      'diode ladder' => -> { tiny.().diode(500, resonance: 0.3) },
      'formant' => -> { tiny.().formant(:a, :o, morph: 0.5) },
      # (sustain: false: the sustain shelf's pitch tracking still differs in
      # the last bit by buffer size, fixes-7 found)
      'SVF in a feedback loop' => -> { tiny.().feedback(sustain: false) { |fb, input| input + fb.delay(30.samples).filter(:lowpass, cutoff: 3000, quality: 0.7) * 0.5 } },
    }.each do |name, make|
      [false, true].each do |planned|
        it "gives the same tiny tails at any buffer size for a #{name} (#{planned ? 'planned' : 'unplanned'})" do
          build = -> {
            g = make.() * 1e30
            MB::Sound::Plan.install(g) if planned
            g
          }
          expect_invariant(build, seconds: 0.1, sizes: [[367, 368], [1], [1031]])
        end
      end
    end
  end

  describe 'Synth idle lane skipping' do
    clip = -> { MB::Sound.seq(MB::Sound::C4.n16, MB::Sound::Rest.n4, MB::Sound::E4.n16, MB::Sound::Rest.n2, MB::Sound::G4.n8.d, MB::Sound::Rest.n4).loop }
    patches = {
      'noise' => ->(v) { MB::Sound.noise.filter(:highpass, cutoff: 5000, quality: 0.7) * v.env(0.001, 0.05, 0, 0.05) },
      'free saw' => ->(v) { v.hz.saw.free.filter(:lowpass, cutoff: 2000, quality: 1) * v.amp_env(0.001, 0.1, 0.5, 0.05) },
      'synced saw and eased noise' => ->(v) {
        v.hz.saw.sync(ratio: 1.7).filter(:lowpass, cutoff: 3000, quality: 1) * v.amp_env(0.001, 0.1, 0.5, 0.05) +
          MB::Sound.noise.ease(:smooth) * v.env(0.001, 0.03, 0, 0.02) * 0.2
      },
      'free LFO and controllers' => ->(v) { v.hz.aramp * v.amp_env(0.001, 0.1, 0.5, 0.05) * (1 + 3.hz.lfo * 0.5) * (1 + v.mod) },
    }

    [true, false].each do |lanes|
      patches.each do |name, patch|
        it "gives the same samples at any buffer size for a #{name} patch (lane groups #{lanes ? 'on' : 'off'})" do
          old = MB::Sound::Plan.lanes
          MB::Sound::Plan.lanes = lanes
          skipped = []
          make = -> {
            s = clip.call.synth(voices: 2) { |v, _i| patch.(v) }
            skipped << s
            s
          }
          # (Tones with a frequency signal, v.hz, keep a running phase
          # wrapped every sample since fixes-6, so these are exact too)
          expect_invariant(make, seconds: 3)
        ensure
          MB::Sound::Plan.lanes = old
        end
      end
    end

    it 'gives the same samples with one-sample buffers' do
      old = MB::Sound.bpm
      MB::Sound.bpm(480)
      expect_invariant(-> { clip.call.synth(voices: 2) { |v, _i| patches['noise'].(v) } }, seconds: 0.4, sizes: [[1]])
    ensure
      MB::Sound.bpm(old)
    end

    # With exact_lanes (Synth#exact_lanes?; renders and takes can ask for
    # it), lanes become free for new notes by their quiet state over whole
    # grid cells (fixes-7): measured per buffer, a released lane was free at
    # 367/368 but not at 800 when a note came, so the note went to another
    # lane, whose free-running sine had another phase (a persona take's
    # keys, +1.2 dB)
    [:string, :reuse].each do |retrigger|
      it "allocates the same lanes at any buffer size (retrigger: #{retrigger})" do
        notes = MB::Sound.seq(
          MB::Sound::C4.n32, MB::Sound::E4.n32, MB::Sound::Rest.n64, MB::Sound::C4.n32, MB::Sound::G4.n64,
          MB::Sound::Rest.n32.t, MB::Sound::E4.n32, MB::Sound::C4.n64.d, MB::Sound::Rest.n16
        ).humanize(1.n128).loop
        make = -> {
          MB::Sound.seed(3)
          notes.synth(voices: 3, retrigger: retrigger, exact_lanes: true) { |v| v.hz.sine.free * v.amp_env(0.001, 0.02, 0, 0.012) }
        }
        expect_invariant(make, seconds: 3, sizes: [[367, 368], [1], [1031], [64]])
      end
    end

    it 'aligns the grid of a Synth launched off it with the Session frames (no split 800-sample buffers)' do
      # A synth launched at frame 13714: its grid (where lanes are measured
      # for the allocator) falls on Session frames that are multiples of
      # 800, so 800-sample buffers are read whole (fixes-7); other sizes
      # split and give the same samples
      results = [[800], [367, 368], [1031]].map { |sizes|
        out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
        s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
        s.exact_lanes = true
        MB::Sound.seed(3)
        syn = clip.call.synth(voices: 2, retrigger: :string) { |v| v.hz.sine.free * v.amp_env(0.001, 0.02, 0, 0.012) }
        pieces = 0
        syn.define_singleton_method(:sample_lanes_piece) { |n| pieces += 1; super(n) }
        s.add(syn, name: :x, start_time: 1/7r)
        data = []
        i = 0
        while s.frame < 96_000
          data << s.process_buffer(sizes[i % sizes.length])[0].dup
          i += 1
        end
        s.close
        expect(syn.exact_lanes?).to eq(true)
        expect(pieces).to eq(i - 17) if sizes == [800] # one piece per buffer once it started (frame 13714, in buffer 17)
        data.reduce(:concatenate)
      }
      n = results.map(&:length).min
      results.each { |r| expect(r[0...n]).to eq(results[0][0...n]) }
      expect(results[0].abs.max).to be > 0.1
    ensure
      MB::Sound.rewind
    end

    it 'reads whole buffers without exact_lanes (the default) at any buffer size' do
      syn = clip.call.synth(voices: 2) { |v| v.hz.sine.free * v.amp_env(0.001, 0.02, 0, 0.012) }
      expect(syn.exact_lanes?).to eq(false)
      pieces = 0
      syn.define_singleton_method(:sample_lanes_piece) { |n| pieces += 1; super(n) }
      100.times { syn.sample(367) }
      expect(pieces).to eq(100)
    ensure
      MB::Sound.rewind
    end

    it 'skips lanes in the invariance cases (so the cases test something)' do
      old = MB::Sound::Plan.lanes
      MB::Sound::Plan.lanes = false
      s = clip.call.synth(voices: 2) { |v, _i| patches['noise'].(v) }
      count = 0
      100.times { s.sample(367); count += s.skipped_lanes.length }
      expect(count).to be > 50
    ensure
      MB::Sound::Plan.lanes = old
      MB::Sound.rewind
    end
  end

  describe 'Synth sub-lanes' do
    it 'wake sleeping instrument layers on the same samples (narrow SF2-style layers)' do
      d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.05) })
      smp = MB::Sound::Sample[d].looped(1000...2900)
      wide = MB::Sound::Sampler::Instrument.new(envelope: [0.002, 0.05, 0.6, 0.03]) { |i| i.region(smp) }
      narrow = MB::Sound::Sampler::Instrument.new(envelope: [0.001, 0.02, 0.5, 0.02], filter: { cutoff: 2000 }) { |i| i.region(smp[0...2000].looped(500...1900), keys: 70..80, tune: 12) }
      inst = MB::Sound::Sampler::Instrument.layered(wide, narrow)
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::B4, MB::Sound::E3, nil, MB::Sound::G4, MB::Sound::A4, nil, MB::Sound::C5).n8.loop
      node = expect_invariant(-> { clip.synth(voices: 3) { |v| inst.play(v) } }, seconds: 1.5)
      parts = node.sub_lanes.flatten
      expect(parts.length).to eq(node.lanes.length)
      expect(parts.sum(&:skipped_samples)).to be > 48000
      expect(parts.sum(&:wakes)).to be > 0
    end
  end
end

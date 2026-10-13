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

    # Lanes become free for new notes by their quiet state over whole grid
    # cells (fixes-7): measured per buffer, a released lane was free at
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
          notes.synth(voices: 3, retrigger: retrigger) { |v| v.hz.sine.free * v.amp_env(0.001, 0.02, 0, 0.012) }
        }
        expect_invariant(make, seconds: 3, sizes: [[367, 368], [1], [1031], [64]])
      end
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
end

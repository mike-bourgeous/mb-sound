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
    out = Numo::SFloat.zeros(total)
    n = 0
    i = 0
    while n < total
      c = [sizes[i % sizes.length], total - n].min
      b = node.sample(c)
      break if b.nil?

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
          # Tones with a frequency signal accumulate their phase per block,
          # which can move the last bit of a float sample (about -140 dB;
          # see design/notes/oscillators.md); everything else is exact
          tol = name == 'noise' ? 0 : -130.db
          expect_invariant(make, seconds: 3, tolerance: tol)
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

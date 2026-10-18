# Same samples at any buffer size, continued from
# buffer_size_invariance_spec.rb (split in test-speed-2 for rake
# spec:parallel): samplers, drum machine voices, and Synths that skip idle
# lanes or sleep sub-lanes.  Helpers in spec/support/buffer_size_helpers.rb.
RSpec.describe 'Buffer size invariance (samplers, drums, Synth lanes)' do
  include BufferSizeHelpers

  describe 'sampler' do
    let(:rec) { MB::Sound::Sample[Numo::SFloat.cast(Numo::DFloat.new(48000).seq.map { |i| Math.sin(i * 0.03) * Math.exp(-(i % 6000) / 2000.0) })] }

    it 'gives the same chop samples at any buffer size (one truncating voice, declick tails, reverse, pitch)' do
      brk = rec.slices(16)
      expect_invariant(-> { brk.chop(0, 3, [5, 2], MB::Sound::Tie, brk[7].rev, 1, MB::Sound::Rest, [2, -3]).loop.sampler(brk) }, sizes: [[367, 368], [64], [1031], [1]],
                       one_sample_seconds: 1.1) # (one-sample buffers through the 1 s pattern into its second pass)
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
        # (one-sample buffers over the first 1.1 s: two passes of the
        # 0.53 s pattern, each humanized differently; the other sizes run
        # all 3 s, about six passes)
        expect_invariant(make, seconds: 3, sizes: [[367, 368], [1], [1031], [64]], one_sample_seconds: 1.1)
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
        SpecBuffers.join(data)
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

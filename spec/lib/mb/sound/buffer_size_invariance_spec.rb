# Same samples at any buffer size (takes and renders promise this):
# oscillator edges landing exactly on samples, resonators, Notes, Synths
# ending, tones, and filter tails (drum machines, samplers, and Synth lane
# skipping are in buffer_size_invariance_synth_spec.rb; the two files were
# one until test-speed-2, split so rake spec:parallel can run them side by
# side).  Each case renders at 800-sample buffers (the usual size) and
# compares other sizes sample for sample, including odd alternating sizes
# (367/368, which put every edge somewhere new) and one-sample buffers
# (helpers in spec/support/buffer_size_helpers.rb).
RSpec.describe 'Buffer size invariance' do
  include BufferSizeHelpers

  # Parameters a node reads per sample, not once per buffer
  # (render_path_guard_spec flags new per-buffer reads; omnibus13)
  describe 'per-sample parameters' do
    it 'switches a wavetable node\'s node-controlled wrap mode on its own sample' do
      table = MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25], size: 64)
      make = -> {
        MB::Sound::GraphNode::Wavetable.new(table: table, phase: 220.hz.ramp.at(0..1.5), sample_rate: 48000, wrap: 3.hz.lfo.at(0..1))
      }
      expect_invariant(make, seconds: 0.7, sizes: [[367, 368], [1031]])
    end
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

      it "asaw and gauss at #{f} Hz stay within -150 dB" do
        expect_invariant(-> { f.hz.asaw }, seconds: 0.5, tolerance: -150.db)
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
        sizes = [[800], *slow_tier([[367, 368], [64], [1031], [1]])]
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
      SpecBuffers.join(out)
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
      # (no one-sample buffers here: the next case is this one with lowpass
      # filters added in the lanes, and runs them; each [1] run of these
      # costs about 5 s)
      'a Synth into a resonant lowpass' => [39_200, -> {
        lp.(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8.synth(voices: 4) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05) })
      }, false],
      'a Synth with resonant filters in its lanes' => [44_800, -> {
        lp.(MB::Sound.seq(MB::Sound::C3, MB::Sound::E4, MB::Sound::G4).n8.synth(voices: 4) { |v|
          (v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05)).filter(:lowpass, cutoff: 300, quality: 20)
        })
      }],
      'a Synth with a 1 s tail' => [75_200, -> {
        lp.(MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8, voices: 2, tail: 1) { |v| v.hz.saw * v.amp_env(0.01, 0.1, 0.5, 0.05) })
      }],
    }.each do |what, (length, make, one_sample)|
      it "ends #{what} on the same sample at any buffer size" do
        ref = until_end(make, [800])
        expect(ref.length).to eq(length)
        slow_tier([[367, 368], [64], [1031], *([[1]] unless one_sample == false)]).each do |s|
          out = until_end(make, s)
          expect(out.length).to eq(length), "at buffer sizes #{s}"
          # (planned :fast sines differ within -100 dB at other block sizes)
          expect((out - ref).abs.max).to be <= 1e-5 * ref.abs.max, "at buffer sizes #{s}"
        end
      end
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
      'naive ramp' => -> { fm.().asaw },
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
      'BLIT complex ramp' => -> { fm.().complex_saw },
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
      'BLIT complex ramp' => ->(f) { f.tone.complex_saw },
      'cycle wavetable' => ->(f) { f.tone.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5], size: 64)) },
    }.each do |name, make|
      it "gives the Ruby mirror's samples for a #{name} with wild frequencies" do
        tones = [:c, :ruby].map { |m|
          MB::Sound.seed(5)
          [m, make.(MB::Sound.noise.at(150_000) + 300.hz.at(400))]
        }
        [128, 37, 800].each do |n|
          a, b = tones.map { |m, t| sample_with(m, t, n).dup }
          expect(b.to_a).to eq(a.to_a)
        end
      end
    end

    [false, true].each do |planned|
      tones.each do |name, make|
        it "gives the same samples at any buffer size for a #{name} (#{planned ? 'planned' : 'unplanned'})" do
          build = -> {
            g = make.() * 0.5
            MB::Sound::Plan.install(g, check: nil) if planned # (check mode reruns blocks unfused: :fast regions differ)
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
      'naive ramp' => -> { 220.3.hz.asaw },
      'phasor' => -> { 3.3.hz.phasor },
      'LFO' => -> { 0.31.hz.lfo },
      'PolyBLEP saw' => -> { 220.3.hz.saw },
      'PolyBLEP square, pwm signal' => -> { 220.3.hz.square.pwm(3.hz.lfo.at(0.2..0.8)) },
      'BLIT complex ramp' => -> { 220.3.hz.complex_saw },
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
            MB::Sound::Plan.install(g, check: nil) if planned # (check mode reruns blocks unfused: :fast regions differ)
            g
          }
          expect_invariant(build, seconds: 0.7, sizes: [[367, 368], [1], [1031]])
        end
      end
    end

    {
      'naive sine' => -> { 220.3.hz.sine },
      'PolyBLEP square' => -> { 220.3.hz.square.pwm(0.3) },
      'BLIT complex ramp' => -> { 220.3.hz.complex_saw },
      'cycle wavetable' => -> { 220.3.hz.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5], size: 64)) },
      'feedback sine' => -> { 220.3.hz.sine.fm_feedback(0.3) },
      'cycle wavetable, width signal' => -> { 220.3.hz.wavetable(MB::Sound::Wavetable.from_harmonics([1, 0.5, 0.25], size: 64)).pwm(MB::Sound.noise.at(0.1..0.9)) },
      'sample wavetable (looped)' => -> {
        s = Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) }
        220.3.hz.wavetable(MB::Sound::Wavetable.from_samples(s, mode: :sample, root: 200, loop: 1000...4000))
      },
    }.each do |name, make|
      it "gives the Ruby mirror's samples and state for a #{name} across grid points" do
        tones = [:c, :ruby].map { |m|
          MB::Sound.seed(5)
          [m, make.()]
        }
        [367, 1, 1031, 800, 433].each do |n|
          a, b = tones.map { |m, t| sample_with(m, t, n).dup }
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
            MB::Sound::Plan.install(g, check: nil) if planned # (check mode reruns blocks unfused: :fast regions differ)
            g
          }
          expect_invariant(build, seconds: 0.1, sizes: [[367, 368], [1], [1031]])
        end
      end
    end
  end
end

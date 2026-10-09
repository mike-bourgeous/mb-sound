# Event-driven nodes in plans (Notes nodes, envelopes; see
# MB::Sound::Plan::EventList): planned in C and with the Ruby mirror against
# the unfused graph, bit for bit, over block sizes from 1 to 800, on MIDI
# files with dense notes and controllers.
RSpec.describe('Plan: Notes nodes and envelopes') do
  # A pass over SIZES is about 0.13 s; four cover the files' first notes,
  # chords, retriggers, and releases.
  let(:sizes) { PlanSpecHelpers::SIZES * 4 }

  let(:dense) { 'spec/test_data/dense_modulated.mid' }

  # Compares samples (C bit-exact; tones' Ruby kernels in the mirror differ
  # from C by rounding), then runs the C plans again in check mode, which
  # also compares every node's state after each block (e.g. a glide's
  # position).
  def compare(file = dense, sizes: self.sizes, **kw, &block)
    r = plan_compare(sizes: sizes, ruby_tolerance: 1e-6, **kw) { |c| block.call(MB::Sound::Notes.new(file), c) }
    plan_compare(sizes: sizes, engines: [:c], check: :raise, fallbacks: true) { |c| block.call(MB::Sound::Notes.new(file), c) }
    r
  end

  # Op class names in every region of the C plans.
  def op_names(result)
    result.regions.flat_map { |r| r.program.ops.map { |op| op.class.name.split('::').last.to_sym } }.uniq
  end

  describe 'note nodes' do
    [:gate, :trigger, :choke, :number, :velocity, :lift, :key_trigger].each do |name|
      it "matches #{name}" do
        r = compare { |v| v.public_send(name) * 0.5 }
        expect(op_names(r)).to include(:Events)
        expect(r.regions.first.members.grep(MB::Sound::Notes::Node)).not_to be_empty
      end
    end

    it 'matches note nodes on a file with the sustain pedal' do
      compare('spec/test_data/c2_sustain.mid') { |v| v.gate + v.number * 0.01 + v.trigger }
    end

    it 'matches key_trigger next to :add envelopes (re-strikes of sounding notes left out)' do
      compare { |v| v.hz.sine * v.amp_env(0.01, 0.2, 0.5, 0.3, retrigger: :add) + v.key_trigger }
    end

    it 'matches through a seek (note-offs and chases of held values)' do
      compare { |v, c|
        c.before_block(30) { v.stream.seek(2.0) }
        v.gate + v.number * 0.01 + v.velocity + v.trigger
      }
    end
  end

  describe 'controllers' do
    it 'matches smoothed controllers, bend, and channel pressure' do
      r = compare { |v| v.cc(1) + v.mod * 0.5 + v.bend * 0.25 + v.bend_semitones * 0.1 + v.pressure + v.cc(74, smooth: false) * 0.3 }
      expect(op_names(r)).to include(:Smooth)
    end

    it 'matches adaptive smoothing' do
      r = compare { |v| v.cc(1, smooth: :adaptive) + v.bend(smooth: 2.ms..80.ms) * 0.25 + v.poly_pressure(smooth: :adaptive) }
      expect(op_names(r)).to include(:Smooth)
    end

    it 'matches live changes of the global smoothing defaults' do
      compare { |v, c|
        c.before_block(10) { MB::Sound::Notes.control_smoothing = 40.ms }
        c.before_block(20) { MB::Sound::Notes.bend_smoothing = :adaptive }
        c.before_block(30) { MB::Sound::Notes.control_smoothing = false }
        c.before_block(40) { MB::Sound::Notes.control_smoothing = 5.ms..30.ms }
        v.cc(1) + v.mod * 0.5 + v.bend * 0.25 + v.pressure + v.cc(74, smooth: 20.ms) * 0.3
      }
    end

    it 'filters each controller\'s own events (several CCs in one feed group)' do
      compare { |v| v.cc(1) * v.attack_time + v.cc(7) * v.release_time * v.decay_time }
    end

    it 'matches poly pressure (jumps at note-ons) and aftertouch' do
      # (the file ends early, and its nodes then become boundaries)
      compare('spec/test_data/poly_pressure.mid', fallbacks: true) { |v| v.poly_pressure + v.aftertouch * 0.5 }
      r = compare { |v| v.poly_pressure + v.aftertouch * 0.5 }
      expect(op_names(r)).to include(:Smooth, :Max)
    end

    it 'matches a delayed LFO (FadeIn ramps)' do
      r = compare { |v| v.lfo(7, delay: 0.05) + v.hz.vibrato(6, depth: 30.cents, delay: 0.03).sine * 0.5 }
      expect(r.regions.first.members.grep(MB::Sound::Notes::FadeIn)).not_to be_empty
    end
  end

  describe 'Glide' do
    it 'matches a smoothstep glide' do
      r = compare { |v| v.hz.glide(30.ms).send(:number_node) * 0.01 }
      expect(op_names(r)).to include(:Events)
    end

    it 'matches a glide with overshoot and a frequency' do
      compare { |v| v.hz.glide(25.ms, overshoot: 0.3).sine * 0.5 }
    end

    it 'matches a curve glide (rendered samples)' do
      compare { |v| v.hz.glide(20.ms, shape: :elastic).sine * 0.5 }
    end
  end

  describe 'Frequency' do
    it 'matches the frequency with bend and transposition, keeping its value' do
      r = compare { |v| v.hz.transpose(7).freq * 0.001 }
      expect(op_names(r)).to include(:NoteFreq, :Keep)
    end
  end

  describe 'envelopes' do
    it 'matches amp_env, fm_env, and filter_env (GM time scaling from controllers)' do
      r = compare { |v| v.amp_env + v.fm_env(0, 0.2, 0, 0.1) + v.filter_env(0.01, 0.3, 0.2, 0.2, depth: 2) * 0.1 }
      expect(op_names(r)).to include(:Envelope, :Events)
    end

    it 'matches a region rooted at a Notes envelope (its own #sample bookkeeping doesn\'t run too)' do
      r = compare { |v| v.amp_env(0.01, 0.1, 0.5, 0.2) }
      expect(r.regions.first.root).to be_a(MB::Sound::Notes::NoteEnvelope)
    end

    it 'matches multi-segment, looping, and S-shaped envelopes' do
      compare { |v|
        v.env([[1, 0.01], [0.3, 0.02, 0, :s], [0.8, 0.03], [0, 0.05]], release_at: 3, loop: 1) +
          v.env(0.005, 0.05, 0.4, 0.1, shape: :s)
      }
    end

    it 'matches :add retrigger, legato, lift, and restart' do
      compare { |v|
        v.amp_env(0.01, 0.1, 0.5, 0.2, retrigger: :add) + v.env(0.01, 0.1, 0.5, 0.2, lift: true).legato +
          v.env(0.02, 0.1, 0.5, 0.2, retrigger: :zero)
      }
    end

    it 'builds no GM time node (no 0 * x fold) for zero-length segments, sounding the same' do
      r = compare { |v| v.env(0, 0, 1, 0, gate: false, hold: 0.05) + v.amp_env(0.01, 0, 0.6, 0.1) + v.fm_env(0.seconds, 0.2, 0, 0) }
      expect(r.regions.flat_map { |g| g.folds || [] }).to eq([])
      n = MB::Sound::Notes.new(dense)
      e = n.env(0, 0, 1, 0, gate: false, hold: 0.05)
      expect(e.instance_variable_get(:@gm_nodes).keys).to eq([])
      gm_off = MB::Sound::Notes.new(dense).env(0, 0, 1, 0, gate: false, hold: 0.05).gm(false)
      expect(Array.new(20) { e.sample(256)&.dup }).to eq(Array.new(20) { gm_off.sample(256)&.dup })
    end

    it 'matches envelopes without GM scaling and with node parameters' do
      compare { |v|
        lfo = 2.hz.lfo.at(0.3..0.7)
        v.env(0.01, 0.1, lfo, 0.2).gm(false) + v.env(0.01, 0.05, 0.5, 0.1, curve: lfo * 20)
      }
    end

    it 'matches a plain envelope on a tone gate (and a one-shot)' do
      plan_compare(sizes: sizes, ruby_tolerance: 1e-6) {
        gate = 3.hz.lfo.asquare.at(0..1)
        MB::Sound.adsr(0.01, 0.05, 0.5, 0.1, gate: gate) * 300.hz.sine + MB::Sound.adsr(0.01, 0.02, 0.5, 0.03, hold: 0.05) * 1
      }
    end

    it 'reads an input that ends as the envelope does (the block replays, then a constant)' do
      r = plan_compare(sizes: sizes, ruby_tolerance: 1e-6, fallbacks: true) {
        vel = PlanSpecHelpers::Source.new(kind: :steps, every: 700, scale: 0.4, offset: 0.5, ends_at: 3000)
        gate = 7.hz.lfo.asquare.at(0..1)
        MB::Sound.adsr(0.01, 0.05, 0.5, 0.1, gate: gate, velocity: vel) * 1
      }
      expect(r.regions.sum(&:unfused_blocks)).to be <= 2
    end

    it 'matches an fm_bass voice' do
      r = compare { |v|
        base = v.hz.glide(100.ms)
        base2x = base.transpose(12)
        mod = v.cc(1, range: 1.0..2.0)
        cenv = v.fm_env(0, 0.2, 0, 0.1, sensitivity: -7.db..0.db)
        c = cenv * base2x.complex_sine.at(1).pm(cenv * mod * base2x.at(1))
        denv = v.fm_env(0, 0.3, 0, 0.35)
        d = denv * (base2x.freq * 0.9996 - 0.22).tone.complex_sine.at(1).reset(v.trigger)
        fenv = v.amp_env(0.001, 2, 0.699, 0.5, curve: [-10, 2, 8])
        (fenv * base.complex_sine.at(1).pm((c + d) * mod)).real * 0.125
      }
      expect(r.regions.first.members.length).to be > 30
    end
  end

  describe 'the end of a stream' do
    it 'runs blocks unfused once the stream is over, with the same samples' do
      r = compare('spec/test_data/c_major.mid', fallbacks: true) { |v, c|
        c.before_block(0) { v.stream.seek(5.6) }
        v.hz.sine * v.amp_env(0.01, 0.1, 0.5, 0.1) + v.gate
      }
      expect(r.installations[:c].excluded.values).to include('its MIDI stream is over')
    end
  end

  describe 'Synth lanes' do
    it 'keeps skipped lanes in step without replanning (Notes::Node#advance)' do
      s = MB::Sound::Synth.new(dense, voices: 3) { |v| v.hz.saw * v.amp_env(0.005, 0.05, 0.3, 0.05) }
      plans = s.instance_variable_get(:@plans)
      200.times { s.sample(256) }
      excluded = plans.compact.flat_map { |i| i.excluded.keys }
      expect(excluded).to be_empty
    end
  end

  describe 'filter parameter nodes' do
    it 'matches cutoff (base, GM brightness, filter envelope, key tracking), quality, and reso with their filters' do
      r = compare { |v|
        sig = v.hz.saw
        a = sig.filter(:lowpass, cutoff: v.cutoff(400, env: v.filt_env(0.01, 0.3, 0.4, 0.2, depth: 3), keytrack: 1), quality: v.quality(2))
        b = sig.lp4(v.cutoff(800), resonance: v.reso(0.6))
        (a + b) * v.amp_env
      }
      expect(op_names(r)).to include(:Exp, :Clip, :FilterSvf, :FourPole)
      members = r.regions.flat_map(&:members)
      expect(members.grep(MB::Sound::Notes::Cutoff).length).to eq(2)
      expect(members.grep(MB::Sound::Notes::Quality).length).to eq(1)
      expect(members.grep(MB::Sound::Notes::Resonance).length).to eq(1)
    end

    it 'matches parameter nodes with node bases, without GM controllers, and without key tracking' do
      compare { |v|
        sig = v.hz.ramp
        c = v.cutoff(v.velocity * 2000 + 300, env: false, keytrack: 0, gm: false)
        sig.filter(:bandpass, cutoff: c, quality: v.quality(v.velocity * 3 + 0.5, gm: false)).lp4(900, resonance: v.reso(v.velocity, gm: false)) * v.env
      }
    end

    it 'matches SQ-80 velocity and key time scaling' do
      r = compare { |v| v.hz.sine * v.sq80_env(t1: 20, t2: 30, t3: 25, t4: 30, l1: 63, l2: 40, l3: 30, t1v: 40, tk: 30) }
      expect(op_names(r)).to include(:TimeScale)
    end
  end
end

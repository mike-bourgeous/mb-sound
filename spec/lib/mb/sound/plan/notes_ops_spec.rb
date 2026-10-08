# Event-driven nodes in plans (Notes nodes, envelopes; see
# MB::Sound::Plan::EventList): planned in C and with the Ruby mirror against
# the unfused graph, bit for bit, over block sizes from 1 to 800, on MIDI
# files with dense notes and controllers.
RSpec.describe('Plan: Notes nodes and envelopes') do
  # A pass over SIZES is about 0.13 s; four cover the files' first notes,
  # chords, retriggers, and releases.
  let(:sizes) { PlanSpecHelpers::SIZES * 4 }

  let(:dense) { 'spec/test_data/dense_modulated.mid' }

  # Tones' Ruby kernels (the mirror) differ from C by rounding
  def compare(file = dense, sizes: self.sizes, **kw, &block)
    plan_compare(sizes: sizes, ruby_tolerance: 1e-6, **kw) { |c| block.call(MB::Sound::Notes.new(file), c) }
  end

  def op_names(result)
    plan_op_names(result).uniq
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
end

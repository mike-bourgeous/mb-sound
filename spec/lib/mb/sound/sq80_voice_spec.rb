require 'digest'

# The SQ-80-flavored voice in the library (MB::Sound.sq80, SQ80::Voice,
# SQ80::Waves, SQ80::PATCHES; design/notes/sq80.md).
RSpec.describe(MB::Sound::SQ80Methods) do
  after { MB::Sound.rewind }

  let(:midi_file) { 'spec/test_data/c_major.mid' }

  # The voice as bin/synths/sq80_voice.rb built it before sq80-lib-1
  # (2026-10-17), kept as the reference the library's defaults must match
  # sample for sample.
  def original_voice(midi, voices: 8, cutoff: 500, reso: 0.4, drive_mode: :feedback, drive: 1.5, chop: 1.5, flutter: 1.0, second_release: false)
    formant = MB::Sound::SQ80::Waves.formant
    synth3 = MB::Sound::SQ80::Waves.synth3
    prime = MB::Sound::SQ80::Waves.prime

    MB::Sound.synth(midi, voices: voices) { |v|
      vibrato = v.lfo(5.2, shape: :tri, depth: 0.06, delay: 0.4, wheel: 0.35, pressure: 0.2)
      osc1 = v.hz.transpose(vibrato).wavetable(formant)
      osc2 = v.hz.transpose(v.mod_sum(0.06, vibrato => 1)).wavetable(synth3)
      osc3 = v.hz.transpose(-12).wavetable(prime)
      env1 = v.sq80_env(l1: 63, l2: 18, l3: 0, t1: 0, t2: 14, t3: 20, t4: 16, lv: 30, cycle: true, restart: true, gm: false)
      env2 = v.sq80_env(l1: 63, l2: 36, l3: 24, t1: 4, t2: 28, t3: 38, t4: 30, lv: 24, t1v: 30, tk: 24, gm: false)
      mods = { env2 => 3.oct, :key => 0.5, :velocity => 0.5.oct, :aftertouch => 1.5.oct }
      if flutter != 0
        flutter_lfo = v.lfo(v.mod_scale(2.5, :poly_pressure => 2.5.oct), shape: :noise)
        mods[flutter_lfo] = v.poly_pressure * flutter.to_f
      end
      if chop != 0
        chopper = v.env([[1, 1.n32, 24], [0, 1.n32, -12], [0, 0.15]], release_at: 2, loop: 0, curve: :linear, sensitivity: 0, gm: false)
        mods[chopper] = chop.to_f.oct
      end
      cut = v.mod_scale(cutoff, mods) * v.brightness
      drive_opts = drive_mode.to_sym == :input ? { drive: drive, drive_mode: :input } : { drive: drive, drive_mode: :feedback, clip: :soft }
      env4 = v.sq80_env(l1: 63, l2: 54, l3: 46, t1: 2, t2: 30, t3: 42, t4: 32, lv: 36, lv_curve: :exp, second_release: second_release)
      ((osc1 * 0.45 + osc2 * 0.35 + osc3 * env1 * 0.4)
        .lp4(cut.clip(20, 18000), resonance: v.reso(reso), **drive_opts) * env4)
    } * 1.6
  end

  # MD5 of +buffers+ buffers from +graph+, sizes 800, 128, and 7 in turn,
  # and the peak.
  def digest(graph, buffers)
    d = Digest::MD5.new
    peak = 0
    buffers.times do |i|
      buf = graph.sample([800, 128, 7][i % 3])
      break if buf.nil?
      d << buf.to_binary
      peak = [peak, buf.abs.max].max
    end
    [d.hexdigest, peak]
  end

  def render(graph, buffers = 30)
    Array.new(buffers) { graph.sample(800)&.dup }.compact
  end

  describe '#sq80' do
    [
      ['the defaults', 'spec/test_data/c_major.mid', {}],
      ['input drive', 'spec/test_data/c_major.mid', { drive_mode: :input, drive: 3.0, reso: 0.7, cutoff: 900 }],
      ['flutter on poly pressure', 'spec/test_data/poly_chord.mid', { flutter: 2.0 }],
      ['no chop, second release', 'spec/test_data/c_major.mid', { chop: 0, second_release: true, voices: 4 }],
    ].each do |label, file, opts|
      it "renders the original voice's samples (#{label})" do
        expected = MB::Sound.with_seed(5) { digest(original_voice(file, **opts), 90) }
        MB::Sound.rewind
        got = MB::Sound.with_seed(5) { digest(MB::Sound.sq80(file, **opts), 90) }
        expect(got).to eq(expected)
        expect(expected[1]).to be > 0.001
      end
    end

    it 'renders the same with Constant nodes for cutoff, reso, chop, and flutter' do
      expected = MB::Sound.with_seed(5) { digest(MB::Sound.sq80(midi_file, :chop), 60) }
      MB::Sound.rewind
      s = MB::Sound::SQ80.patch(:chop).full_settings
      nodes = %i[cutoff reso chop].to_h { |k| [k, s[k].to_f.constant.named(k.to_s)] }
      got = MB::Sound.with_seed(5) { digest(MB::Sound.sq80(midi_file, :chop, **nodes), 60) }
      expect(got).to eq(expected)
    end

    it 'takes the patch before or after the source, and settings over the patch' do
      a = MB::Sound.with_seed(2) { render(MB::Sound.sq80(:glass, midi_file, cutoff: 900)) }
      MB::Sound.rewind
      b = MB::Sound.with_seed(2) { render(MB::Sound.sq80(midi_file, :glass, cutoff: 900)) }
      MB::Sound.rewind
      c = MB::Sound.with_seed(2) { render(MB::Sound.sq80(midi_file, :glass)) }
      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end

    it 'merges Hash settings into the patch and the defaults key by key' do
      v = MB::Sound::SQ80::Voice
      s = v.settings(**v.merge(MB::Sound::SQ80.patch(:glass).settings, env4: { t4: 50 }))
      expect(s[:env4]).to eq(MB::Sound::SQ80::Voice::DEFAULTS[:env4].merge(t1: 0, l2: 40, t2: 34, l3: 0, t3: 44, t4: 50))

      g = MB::Sound.sq80(midi_file, :glass, env4: { t4: 50 })
      expect(render(g, 5).length).to eq(5)
    end

    it 'plays live MIDI without a source' do
      notes = MB::Sound::Notes.new(midi_file)
      allow(MB::Sound).to receive(:midi).and_return(notes)
      g = MB::Sound.sq80(:prime_bass)
      expect(g).to be_a(MB::Sound::GraphNode)
      expect(render(g, 20).map { |b| b.abs.max }.max).to be > 0.001
    end

    it 'explains unknown names with suggestions' do
      expect { MB::Sound.sq80(midi_file, :chopp) }.to raise_error(ArgumentError, /No SQ-80 patch :chopp.*chop/)
      expect { MB::Sound.sq80(midi_file, cutof: 3) }.to raise_error(ArgumentError, /cutof.*cutoff/)
      expect { MB::Sound.sq80(midi_file, osc1: { lvel: 3 }) }.to raise_error(ArgumentError, /osc1 setting :lvel.*level/)
      expect { MB::Sound.sq80(midi_file, osc1: { wave: :sawx }) }.to raise_error(ArgumentError, /sawx.*saw/)
      expect { MB::Sound.sq80(midi_file, drive_mode: :both) }.to raise_error(ArgumentError, /drive_mode/)
      expect { MB::Sound.sq80(midi_file, osc1: { level: 0 }, osc2: { level: 0 }, osc3: { level: 0 }) }.to raise_error(ArgumentError, /level/)
    end

    it 'leaves out oscillators at level 0 and plays library tables' do
      g = MB::Sound.sq80(midi_file, osc1: { wave: :saw }, osc3: { level: 0 })
      expect(render(g, 20).map { |b| b.abs.max }.max).to be > 0.001
    end

    it 'prints itself back as one sq80 call that renders the same' do
      clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8
      g = MB::Sound.sq80(clip, :chop, cutoff: 400)
      text = g.to_ruby(inputs: { clip: clip }, seeds: true)
      expect(text).to match(/^sq80\(clip, :chop, cutoff: 400, seed: \d+\)$/)

      expected = render(g)
      MB::Sound.rewind
      loaded = MB::Sound::GraphIO.load(text, inputs: { clip: MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4).n8 })
      expect(render(loaded)).to eq(expected)
    end
  end

  describe '#sq80_patches' do
    it 'lists every patch with its description and returns the names' do
      names = nil
      expect { names = MB::Sound.sq80_patches }.to output(/:flutter_pad +A slow pad/).to_stdout
      expect(names).to eq(MB::Sound::SQ80::PATCHES.keys)
      expect(names).to include(:classic, :flutter_pad, :chop, :vox_lead, :prime_bass, :glass)
    end
  end

  describe MB::Sound::SQ80::PATCHES do
    it 'has :classic as the defaults' do
      expect(MB::Sound::SQ80.patch(:classic).full_settings).to eq(MB::Sound::SQ80::Voice::DEFAULTS)
    end

    MB::Sound::SQ80::PATCHES.each_key do |name|
      it "builds and plays :#{name}, and loads it as the preset sq80_#{name}" do
        g = MB::Sound.with_seed(3) { MB::Sound.sq80(midi_file, name) }
        out = render(g, 40)
        expect(out.map { |b| b.abs.max }.max).to be_between(0.001, 1.0)

        doc = MB::Sound::GraphIO.parse(MB::Sound::GraphIO.library_presets_dir + "/sq80_#{name}.mbg.rb")
        expect(doc.inputs).to eq([:midi])
        expect(doc.params.keys).to include(:cutoff, :reso)
      end
    end
  end

  describe MB::Sound::SQ80::Waves do
    it 'builds the original tables and passes library names through' do
      expect(described_class[:formant]).to be_a(MB::Sound::Wavetable::KeyMap)
      expect(described_class[:synth3]).to be_a(MB::Sound::Wavetable)
      expect(described_class[:prime]).to equal(described_class.prime)
      expect(described_class[:saw]).to equal(MB::Sound::Wavetable[:saw])
      expect(described_class.names).to include(:formant, :synth3, :prime, :saw)
    end
  end

  describe 'bin/synths/sq80_voice.rb' do
    before(:all) { require File.expand_path('../../../../bin/synths/sq80_voice.rb', __dir__) }

    it 'keeps sq80_voice as the library voice' do
      a = MB::Sound.with_seed(4) { digest(MB::Sound.sq80_voice(midi_file, chop: 2.0), 30) }
      MB::Sound.rewind
      b = MB::Sound.with_seed(4) { digest(MB::Sound.sq80(midi_file, chop: 2.0), 30) }
      expect(a).to eq(b)
    end
  end
end

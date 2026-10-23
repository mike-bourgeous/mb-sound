RSpec.describe('bin/synths/wave_voices.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/wave_voices.rb', __dir__) }

  after { MB::Sound.rewind }

  let(:patches) { %i[digibrass organ_reso square_bass] }

  # A short phrase in each patch's register: two notes, then a chord
  def phrase(patch)
    base = patch == :square_bass ? 36 : 48
    patch_notes([base, 0, 0.3, 1.0], [base + 7, 0.35, 0.65, 1.0], [base + 12, 0.7, 1.1, 1.0], [base + 16, 0.7, 1.1, 1.0])
  end

  # The prototype's ladder (research-sq80, research/sq80/prototype/sq80_voice.rb),
  # copied: a TPT 4-pole with passband compensation and a tanh on the
  # solved input.
  def proto_ladder(input, fc, k:, drive:, comp: 0.375)
    s = [0.0, 0.0, 0.0, 0.0]
    g = Math.tan(Math::PI * fc / 48000.0)
    gg = g / (1 + g)
    one = 1 - gg
    input.to_a.map { |x|
      sum = ((s[0] * one * gg + s[1] * one) * gg + s[2] * one) * gg + s[3] * one
      u = (x * (1 + comp * k) - k * sum) / (1 + k * gg**4)
      y = drive ? Math.tanh(u * drive) / drive : u
      4.times do |j|
        v = gg * (y - s[j])
        y = v + s[j]
        s[j] = y + v
      end
      y
    }
  end

  it "plays the prototype's filter: lp4 at the hardware tuning with each patch's resonance is its ladder" do
    saw = Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| ((i * 110.0 / 48000) % 1) * 2 - 1 }) * 0.35
    MB::Sound::WAVE_VOICES.each do |name, s|
      k = MB::Sound::Filter::FourPole.resonance_curve(s[:reso]) * MB::Sound::Filter::FourPole::MAX_K
      lp4 = ->(drive) { MB::Sound::ArrayInput.new(data: [saw]).lp4(1200, resonance: s[:reso], drive: drive, tuning: :hardware).sample(4800) }
      # Linear: the same filter (the kernel's tan approximation aside)
      ref = Numo::SFloat.cast(proto_ladder(saw, 1200, k: k, drive: nil))
      expect(rms_db(lp4.(nil) - ref) - rms_db(ref)).to be < -90, name.to_s
      # Driven: lp4's rational saturator for the prototype's tanh (-38 dB at 0.35 into drive 1.5)
      ref = Numo::SFloat.cast(proto_ladder(saw, 1200, k: k, drive: s[:drive]))
      expect(rms_db(lp4.(s[:drive]) - ref) - rms_db(ref)).to be < -25, name.to_s
    end
  end

  it 'plays every patch from a MIDI stream, clean and grit, at about the same level' do
    patches.each do |p|
      clean = render_patch(MB::Sound.wave_voice(phrase(p), p), 1.7)[0]
      grit = render_patch(MB::Sound.wave_voice(phrase(p), p, grit: true), 1.7)[0]
      expect(peak_db(clean)).to be_between(-14, 6), p.to_s # (velocity 1, before the master's -10 dB)
      expect(rms_db(grit)).to be_within(1).of(rms_db(clean)), p.to_s
      # (grit: the oscillators held at 38.46 kHz; it must change the sound, not
      # match a size: square_bass's grit is subtle, -41 dB under the clean voice
      # once both render the same lanes (the earlier -40 bound counted a
      # planned/unplanned lane-skipping difference that omnibus12 removed))
      expect(rms_db(grit - clean) - rms_db(clean)).to be > -60, p.to_s
      expect(rms_db(seconds(clean, 1.65, 1.7))).to be < -90 # (released)
    end
  end

  it 'gives digibrass its noise-and-chirp attack and organ_reso its resonant blip' do
    brass = render_patch(MB::Sound.wave_voice(patch_notes([60, 0, 0.5, 1.0]), :digibrass), 0.4)[0]
    plain = MB::Sound::WAVE_VOICES[:digibrass].merge(attack: nil)
    stub_const('MB::Sound::WAVE_VOICES', MB::Sound::WAVE_VOICES.merge(digibrass: plain))
    no_attack = render_patch(MB::Sound.wave_voice(patch_notes([60, 0, 0.5, 1.0]), :digibrass), 0.4)[0]
    diff = seconds(brass - no_attack, 0, 0.05)
    expect(rms_db(diff) - rms_db(seconds(brass, 0, 0.05))).to be > -35 # (-29 dB: a click under the brass)
    expect(rms_db(seconds(brass - no_attack, 0.1, 0.4))).to be < -200 # (the attack is over by 40 ms)

    organ = render_patch(MB::Sound.wave_voice(patch_notes([57, 0, 0.6, 1.0]), :organ_reso), 0.6)[0]
    early = band_share(seconds(organ, 0.005, 0.05), 1500, 6000)
    late = band_share(seconds(organ, 0.4, 0.6), 1500, 6000)
    expect(early).to be > late * 2
  end

  it 'plays from clips and live MIDI through a Session input' do
    clip = MB::Sound.seq(MB::Sound::A1, MB::Sound::A2).n8
    data = render_patch(MB::Sound.wave_voice(clip, :square_bass), 0.6)[0]
    expect(peak_db(data)).to be > -20

    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
    begin
      t = 0.0
      vin = MB::Sound::MIDI::VirtualInput.new(clock: -> { t })
      s.midi_in.add_source(MB::Sound::MIDI::LiveSource.new(vin, latency: 0.02))
      live = MB::Sound::Notes.new(s.midi_in.stream)
      s.add(MB::Sound.preset(:organ_reso, midi: live, session: false, grit: 1), name: :organ, on: :now)
      out = 45.times.map { |i|
        vin.note_on(60, 0.8) if i == 2
        vin.note_off(60) if i == 15
        t += 800 / 48000.0
        s.process_buffer(800)[0].dup
      }
      out = Numo::SFloat.cast(SpecBuffers.join(out))
      expect(rms_db(out[0...1600])).to be < -200
      expect(peak_db(out[3200...12000])).to be > -30
      expect(rms_db(out[-1600..])).to be < -90
    ensure
      s.close
    end
  end

  it 'loads every preset to the same samples as the script, and follows the grit and cutoff params' do
    patches.product([0, 0.5, 1]).each do |p, grit|
      MB::Sound.seed(0)
      direct = render_patch(MB::Sound.wave_voice(phrase(p), p, grit: grit), 0.5)[0]
      MB::Sound.seed(0)
      loaded = render_patch(MB::Sound.preset(p, midi: MB::Sound::Notes.new(phrase(p)), session: false, grit: grit), 0.5)[0]
      expect(loaded).to eq(direct), "#{p} grit #{grit}"
    end

    dark = render_patch(MB::Sound.preset(:square_bass, midi: MB::Sound::Notes.new(phrase(:square_bass)), session: false, cutoff: 60), 0.3)[0]
    bright = render_patch(MB::Sound.preset(:square_bass, midi: MB::Sound::Notes.new(phrase(:square_bass)), session: false, cutoff: 600), 0.3)[0]
    expect(band_share(bright, 500, 4000)).to be > band_share(dark, 500, 4000) * 2
  end

  it 'prints as Ruby that renders the same (recipes and graph documents)' do
    MB::Sound.seed(0)
    graph = MB::Sound.wave_voice(notes = MB::Sound::Notes.new(phrase(:digibrass)), :digibrass, grit: true)
    text = MB::Sound::GraphIO.dump(graph, inputs: { midi: notes })
    expect(text).to include('wavetable_of(', 'tuning: :hardware', '.decimate(38461.5, mix: grit)')
    ref = render_patch(graph, 0.5)[0]
    MB::Sound.seed(5)
    got = render_patch(MB::Sound::GraphIO.load(text, inputs: { midi: MB::Sound::Notes.new(phrase(:digibrass)) }), 0.5)[0]
    expect(got).to eq(ref)
  end
end

RSpec.describe('bin/synths/electric_pianos.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/electric_pianos.rb', __dir__) }

  after { MB::Sound.rewind }

  let(:a3) { MB::Sound::A3.number }

  # Levels of harmonics 2..5 of A3 relative to the first, in dB, from 10
  # to 110 ms after the strike.
  def harmonics(data)
    x = Numo::DFloat.cast(seconds(data, 0.01, 0.11))
    s = Numo::Pocketfft.rfft(x).abs
    h = ->(k) { i = (220.0 * k * x.length / 48000).round; s[(i - 2)..(i + 2)].max }
    (2..5).map { |k| 20 * Math.log10(h.(k) / h.(1)) }
  end

  it 'plays the tine piano in stereo, barking (even harmonics) harder with velocity' do
    soft = render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 0.3]), tremolo: 0), 0.5)
    hard = render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 1.0]), tremolo: 0), 0.5)
    expect(hard.length).to eq(2)
    expect(peak_db(hard[0])).to be_between(-12, 0)
    expect(peak_db(hard[0])).to be > peak_db(soft[0]) + 6
    expect(harmonics(hard[0])[0]).to be > harmonics(soft[0])[0] + 10
    expect(harmonics(hard[0])[2]).to be > harmonics(soft[0])[2] + 6
  end

  it 'plays the reed piano in mono: odd harmonics, growing with velocity' do
    soft = render_patch(MB::Sound.reed_piano_voice(patch_notes([a3, 0, 0.5, 0.3]), tremolo: 0), 0.5)
    hard = render_patch(MB::Sound.reed_piano_voice(patch_notes([a3, 0, 0.5, 1.0]), tremolo: 0), 0.5)
    expect(hard.length).to eq(1)
    expect(peak_db(hard[0])).to be_between(-12, 0)
    h2, h3, h4, h5 = harmonics(hard[0])
    expect([h3, h5].min).to be > [h2, h4].max + 30
    expect(h3).to be > harmonics(soft[0])[1] + 6
  end

  it 'scales the bark' do
    plain = render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 1.0]), tremolo: 0, bark: 0.25), 0.5)[0]
    barky = render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 1.0]), tremolo: 0, bark: 2), 0.5)[0]
    expect(harmonics(barky)[0]).to be > harmonics(plain)[0] + 6
  end

  it 'keeps a hard tine chord out of heavy clipping, with drive: for patches-2\'s hot amp' do
    chord = -> { patch_notes(*[MB::Sound::F3, MB::Sound::A3, MB::Sound::C4, MB::Sound::E4].map { |n| [n.number, 0, 0.5, 1.0] }) }
    clean = render_patch(MB::Sound.tine_piano_voice(chord.(), tremolo: 0, drive: 0.01, level: 32.4), 0.5)[0]
    soft = render_patch(MB::Sound.tine_piano_voice(chord.(), tremolo: 0), 0.5)[0]
    hot = render_patch(MB::Sound.tine_piano_voice(chord.(), tremolo: 0, drive: 1, level: 0.325), 0.5)[0]
    residue = ->(x) { rms_db(x - clean) - rms_db(clean) }
    expect(residue.(soft)).to be < -60 # (clean since patches-4; -27.6 dB at drive 0.25)
    expect(residue.(hot)).to be > -10
    expect(peak_db(soft)).to be_between(-3, 4) # (+3.5 dBFS since patches-4: clean, the master's headroom takes it)
  end

  it 'pushes the tine amp with amp:, keeping quiet notes at their level' do
    chord = -> { patch_notes(*[MB::Sound::F3, MB::Sound::A3, MB::Sound::C4, MB::Sound::E4].map { |n| [n.number, 0, 0.5, 1.0] }) }
    clean = render_patch(MB::Sound.tine_piano_voice(chord.(), tremolo: 0, drive: 0.01, level: 32.4), 0.5)[0]
    residue = ->(amp) { rms_db(render_patch(MB::Sound.tine_piano_voice(chord.(), tremolo: 0, amp: amp), 0.5)[0] - clean) - rms_db(clean) }
    expect(residue.(1)).to be < -60 # (the default amp is clean on a hard chord)
    expect(residue.(2)).to be > -20
    expect(residue.(4)).to be > residue.(2) + 3

    soft = ->(**o) { render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 0.3]), tremolo: 0, **o), 0.3)[0] }
    expect((soft.(amp: 4) - soft.()).abs.max).to be < 1e-5 # (a soft note stays under the clipper's knee)
    expect((soft.(amp: 4.constant) - soft.(amp: 4)).abs.max).to be < 1e-6 # (a node, e.g. a knob)
  end

  it 'scales the pickup drive with pickup:, pickup_velocity:, and (below C4) pickup_key:' do
    f2 = MB::Sound::F2
    # Power above the fundamental (the pickup's harmonics), in dB of the total
    upper = ->(x, f) { 10 * Math.log10(band_share(seconds(x, 0.01, 0.21), f * 1.5, 24000)) }
    reed = ->(n, vel = 0.6, **o) { render_patch(MB::Sound.reed_piano_voice(patch_notes([n.number, 0, 0.5, vel]), tremolo: 0, **o), 0.3)[0] }
    expect(upper.(reed.(f2), f2.frequency)).to be > upper.(reed.(f2, pickup_key: 0), f2.frequency) + 0.5
    expect((reed.(f2) - reed.(f2, pickup_key: 1.5)).abs.max).to be < 1e-6 # (the default since patches-5)
    expect(upper.(reed.(f2), f2.frequency)).to be > upper.(reed.(f2, pickup_key: 1), f2.frequency) + 0.3
    expect(upper.(reed.(f2, pickup_key: 1), f2.frequency)).to be > upper.(reed.(f2, pickup_key: 0.5), f2.frequency) + 0.3
    expect(upper.(reed.(f2, pickup: 2, pickup_key: 1), f2.frequency)).to be > upper.(reed.(f2, pickup_key: 1), f2.frequency) + 1
    c5 = MB::Sound::C5
    expect((reed.(c5) - reed.(c5, pickup_key: 0)).abs.max).to be < 1e-6 # (no key scaling above C4)
    # pickup_velocity: 0 drives soft notes as hard as hard ones
    expect(upper.(reed.(f2, 0.3, pickup_velocity: 0), f2.frequency)).to be > upper.(reed.(f2, 0.3), f2.frequency) + 1
    tine = ->(**o) { render_patch(MB::Sound.tine_piano_voice(patch_notes([a3, 0, 0.5, 1.0]), tremolo: 0, **o), 0.3)[0] }
    expect((tine.(pickup: 0) - tine.()).abs.max).to be > 0.01
    expect((tine.(pickup: 0.5) - tine.()).abs.max).to be < 1e-6 # (the default since patches-4)
  end

  it 'renders each patch from a MIDI file with -p (in a fork)' do
    %w[tine reed].each do |patch|
      out = tmp_path("#{patch}.flac")
      text, status = fork_script('bin/synths/electric_pianos.rb', '-q', '-p', patch, 'spec/test_data/c_major.mid', out)
      expect(status).to be_success, text
      expect(MB::Sound.read(out)[0].abs.max).to be > 0.01
    end
  end
end

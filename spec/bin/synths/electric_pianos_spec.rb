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

  it 'renders each patch from a MIDI file with -p (in a fork)' do
    %w[tine reed].each do |patch|
      out = tmp_path("#{patch}.flac")
      text, status = fork_script('bin/synths/electric_pianos.rb', '-q', '-p', patch, 'spec/test_data/c_major.mid', out)
      expect(status).to be_success, text
      expect(MB::Sound.read(out)[0].abs.max).to be > 0.01
    end
  end
end

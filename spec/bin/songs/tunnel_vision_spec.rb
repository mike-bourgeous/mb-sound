RSpec.describe('bin/songs/tunnel_vision.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/tunnel_vision.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'masters with the club preset at -8.5 LUFS on the loudest 8 bars by default' do
    MB::Sound.render(tmp_path('m.flac'), bars: 0.1) { MB::Sound.tunnel_vision }
    result = MB::Sound::Mastering::Targeting.last
    expect(result).to have_attributes(preset: :club, measure: :loudest)
    expect(result.target.lufs).to eq(-8.5)
  end

  it 'has a 112-bar DJ-friendly form with a snare roll every 16 bars' do
    form = nil
    MB::Sound.render(tmp_path('form.flac'), bars: 0.1) do
      MB::Sound.tunnel_vision
      form = MB::Sound.tunnel_vision_form(play: false)
    end
    expect(form.steps.map(&:first)).to eq([:intro, :build, :drop, :breakdown, :pullup, :drop2, :drop2b, :outro, :tail])
    expect(form.bars).to eq(112)
    expect(form.to_ruby).to include('fill :roll, every: 16', 'drop 32')
  end

  it 'plays the drop loud, the Reese ducked by the kick, under the true-peak ceiling' do
    path = tmp_path('drop.flac')
    MB::Sound.render(path, bars: 2) do
      MB::Sound.tunnel_vision
      MB::Sound.go :drop, on: :now
    end
    data = MB::Sound.read(path)
    peak = data.map { |c| c.abs.max }.max
    expect(peak).to be <= MB::Sound::TV_CEILING.db + 1e-3
    expect(peak).to be > (MB::Sound::TV_CEILING - 2).db

    reese = tmp_path('reese.flac')
    MB::Sound.render(reese, bars: 2) do
      # (Kez's master: the club master's targeting would drive the soloed
      # Reese alone into its limiters, flattening the duck)
      MB::Sound.tunnel_vision(club: nil)
      MB::Sound.go :drop, on: :now
      MB::Sound.solo :reese, on: :now
    end
    mono = MB::Sound.read(reese)[0]
    # (the riff's first note is held for 1.5 beats, 0.52 s; the kick is on 1)
    after_kick = rms_db(seconds(mono, 0.04, 0.12))
    later = rms_db(seconds(mono, 0.25, 0.45))
    expect(after_kick).to be < later - 3
  end
end

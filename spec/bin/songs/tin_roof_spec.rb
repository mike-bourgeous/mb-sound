RSpec.describe('bin/songs/tin_roof.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/tin_roof.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'has a 38-bar form at 60 BPM' do
    form = nil
    MB::Sound.render(tmp_path('form.flac'), bars: 0.05) do
      MB::Sound.tin_roof
      form = MB::Sound.tin_roof_form # (plays; rendered for 0.05 bars)
    end
    expect(form.steps.map(&:first)).to eq([:emerge, :drift, :bloom, :hush, :tide, :dissolve])
    expect(form.bars).to eq(38)
  end

  it 'rains in stereo, each side its own, quietly under the safety limiter' do
    path = tmp_path('rain.flac')
    MB::Sound.render(path, bars: 0.5) do
      MB::Sound.tin_roof
      MB::Sound.go :emerge, on: :now
    end
    l, r = MB::Sound.read(path)
    expect(rms_db(l)).to be_between(-60, -15)
    expect(l).not_to eq(r)
    expect([l.abs.max, r.abs.max].max).to be <= -1.db + 1e-3
  end
end

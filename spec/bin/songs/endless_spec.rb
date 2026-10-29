# bin/songs/endless.rb: the endless ambient (genre(:ambient).endless, G4).
RSpec.describe('bin/songs/endless.rb', :aggregate_failures) do
  before(:all) { require File.expand_path('../../../bin/songs/endless.rb', __dir__) }

  after { MB::Sound::Session.existing&.close }

  it 'plays the ambient template forever, moods by a chain (another per seed)' do
    t = MB::Sound.endless_ambient
    expect(t.form).to be_generative
    first = t.form.plan(seed: 0).first(40).map(&:section)
    expect(first.first).to eq(:emerge)
    expect(first.uniq.length).to be >= 5
    expect(MB::Sound.endless_ambient(seed: 2).form.plan(seed: 0).first(40).map(&:section)).not_to eq(first)
    lines = MB::Sound.endless_plan(t, 3)
    expect(lines[0]).to match(/bar\s+1\s+0:00\s+emerge\s+8 bars/)
    expect(lines.length).to eq(3)
  end

  it 'renders the start with the drone, bowls, and rain playing' do
    path = tmp_path('endless.flac')
    MB::Sound.render(path, bars: 2, tail: false, loudness: false) { MB::Sound.endless_ambient.play }
    data = MB::Sound.read(path)
    expect(data[0].length).to be_within(48).of(2 * 4 * 48000)
    peak = data.map { |c| c.abs.max }.max
    expect(peak).to be_between(0.005, 1.0)
  end
end

RSpec.describe('bin/songs/generative_steer.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/generative_steer.rb', __dir__) }

  after { MB::Sound.rewind }

  # Renders +bars+ bars of the piece; returns [clips, audio].
  def steer_piece(bars, **opts)
    path = tmp_path("steer_#{opts.hash.abs}.flac")
    clips = nil
    MB::Sound.render(path, bars: bars) { clips = MB::Sound.generative_steer(**opts) }
    [clips, MB::Sound.read(path)]
  end

  it 'fills the lead in over the intro (the density gesture) and thickens the drums, unlike the fixed version' do
    clips, audio = steer_piece(10)
    expect(audio.map { |c| c.abs.max }.max).to be_between(0.1, 1.0)
    lead = (0..8).map { |c| clips[:lead].events_for(c).length }
    drums = (0..9).map { |c| clips[:drums].events_for(c).length }
    expect(lead.first).to be <= 4
    expect(lead[7]).to be >= lead.first + 6
    expect(drums.last(2).sum).to be > drums.first(2).sum

    fixed, = steer_piece(10, steer: false)
    flat = (0..8).map { |c| fixed[:lead].events_for(c).length }
    expect(flat.max - flat.min).to be <= 4
  end

  it 'plays the build scene without a form' do
    clips = nil
    path = tmp_path('free.flac')
    MB::Sound.render(path, bars: 1) { clips = MB::Sound.generative_steer(form: false) }
    expect(clips.keys).to eq(%i[drums bass lead pad])
    expect(MB::Sound.read(path).map { |c| c.abs.max }.max).to be > 0.05
  end
end

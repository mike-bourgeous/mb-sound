RSpec.describe('bin/songs/small_talk.rb') do
  before(:all) { load File.expand_path('../../../bin/songs/small_talk.rb', __dir__) }

  after { MB::Sound.rewind }

  let(:bar) { (48000 * 240 / 125.0) }

  it 'has an 89-bar form with a 2/4 gap and a pick between two second pickups' do
    form = nil
    MB::Sound.render(tmp_path('form.flac'), bars: 0.1) do
      MB::Sound.small_talk
      form = MB::Sound.small_talk_form(play: false)
    end

    expect(form.steps.map(&:first)).to eq([:intro, :groove, :tease, :drop, :pickup, :breakdown, :lift, :gap, :drop2, :pickup2, :outro, :tail])
    expect(form.bars).to eq(89)
    expect(form.to_ruby).to include('callback 8', 'pickup2 8', 'gap 1')
  end

  it 'plays the drop: a talking bass ducked by the kick, limited at the master ceiling' do
    talk = tmp_path('talk.flac')
    MB::Sound.render(talk, bars: 2) do
      MB::Sound.small_talk
      MB::Sound.go :drop, on: :now
      MB::Sound.solo :talk, on: :now
    end
    data = MB::Sound.read(talk)
    mono = Numo::SFloat.cast(data[0])

    # Just after each kick vs. late in each beat (the duck pulls the bass
    # down about 16 dB for 30-100 ms after each kick, recovering by the
    # next one)
    beat = bar / 4
    rms = ->(from, len) { s = mono[from.round...(from + len).round]; Math.sqrt((s**2).mean) }
    kicks = (1...8).sum { |b| rms.(b * beat + 0.03 * 48000, 0.03 * 48000) }
    middles = (1...8).sum { |b| rms.(b * beat + 0.35 * 48000, 0.03 * 48000) }
    expect(middles).to be > 0.05
    expect(kicks).to be < middles * 0.3

    full = tmp_path('drop.flac')
    MB::Sound.render(full, bars: 2) do
      MB::Sound.small_talk
      MB::Sound.go :drop, on: :now
    end
    data = MB::Sound.read(full)
    peak = data.map { |c| c.abs.max }.max
    expect(peak).to be <= MB::Sound::SMALL_TALK_CEILING.db + 1e-6
    expect(peak).to be > (MB::Sound::SMALL_TALK_CEILING - 2).db
  end

  it 'dives only held notes: the tease ends on one bar-long G1, and the hook never dives' do
    tease = MB::Sound::SMALL_TALK_TEASE
    expect(tease.length).to eq(8)
    last = tease.events.max_by(&:start)
    expect([last.start, last.length, last.value]).to eq([7, 1, MB::Sound::G1.number])

    render = ->(dive) {
      path = tmp_path("hook_#{dive}.flac")
      MB::Sound.render(path, bars: 2) do
        MB::Sound.bpm 125
        MB::Sound.bg :t, MB::Sound.small_talk_bass(MB::Sound::SMALL_TALK_HOOK, dive: dive), fade: 0
      end
      MB::Sound.read(path)[0]
    }
    expect(render.(48)).to eq(render.(0))
  end
end

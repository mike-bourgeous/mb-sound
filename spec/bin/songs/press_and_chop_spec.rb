RSpec.describe('bin/songs/press_and_chop.rb', :aggregate_failures) do
  before(:all) { require File.expand_path('../../../bin/songs/press_and_chop.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'presses a two-bar record at its own tempo and cuts it into named sixteenths' do
    rec = MB::Sound.press_and_chop_record
    expect(rec.length).to eq((48000 * 60 / MB::Sound::PRESS_AND_CHOP_RECORD_BPM * 8).round)
    expect(rec.bpm).to eq(MB::Sound::PRESS_AND_CHOP_RECORD_BPM)
    brk = MB::Sound.press_and_chop_break(rec, lofi: :none)
    expect(brk.length).to eq(32)
    expect(brk[:sk].length).to eq(brk[4..7].length)
    chops = MB::Sound.press_and_chop_chops(brk)
    expect(chops[:a].length).to eq(2)
    expect(chops[:b].length).to eq(4)
    expect(chops[:roll].length).to eq(4)
  end

  it 'plays the chops on the song grid, three semitones up' do
    path = tmp_path('song.flac')
    MB::Sound.render(path, bars: 6) {
      MB::Sound.press_and_chop
      MB::Sound.at_bar(5) { MB::Sound.solo :breaks, on: :now }
    }
    mono = MB::Sound.read(path)[0]
    bar = 48000 * 240 / 165.0
    sixteenth = bar / 16
    on = MB::Sound::Sample[mono[(4 * bar).round...(6 * bar).round]].onsets
    expect(on.length).to be >= 16
    on.each { |o| expect((o / sixteenth - (o / sixteenth).round).abs).to be < 0.05 }
    expect(mono.abs.max).to be <= 10**(-1 / 20.0) + 1e-4 # the limiter's ceiling (sample peaks)
  end
end

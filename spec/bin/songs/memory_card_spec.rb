RSpec.describe('bin/songs/memory_card.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/memory_card.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'has a 96-bar form, the breakdown building into the second drop' do
    form = nil
    MB::Sound.render(tmp_path('form.flac'), bars: 0.1) do
      MB::Sound.memory_card
      form = MB::Sound.memory_card_form(play: false)
    end
    expect(form.steps.map(&:first)).to eq([:intro, :lift, :roll, :drop, :breakdown, :drop2, :outro, :outro2])
    expect(form.bars).to eq(96)
    expect(form.to_ruby).to include('breakdown 16, fill: [:build, 4]')
  end

  it 'chops the break on the song grid: chop A puts a kick on every downbeat' do
    path = tmp_path('breaks.flac')
    MB::Sound.render(path, bars: 2) do
      MB::Sound.memory_card
      MB::Sound.go :drop, on: :now
      MB::Sound.solo :breaks, on: :now
    end
    mono = MB::Sound.read(path)[0]
    bar = 48000 * 240 / 165.0
    sixteenth = bar / 16
    # A kick (low) on each downbeat, the snare (higher) on beat 2
    [0, bar].each do |down|
      kick = mono[down.round...(down + 0.05 * 48000).round]
      snare = mono[(down + 4 * sixteenth).round...(down + 4 * sixteenth + 0.05 * 48000).round]
      expect(peak_db(kick)).to be > -12
      expect(band_share(kick, 20, 150)).to be > band_share(snare, 20, 150) * 2
    end
    peak = MB::Sound.read(path).map { |c| c.abs.max }.max
    expect(peak).to be <= -1.db + 1e-3
  end

  it "masters with Nev's chain by default and the vinyl preset with vinyl: true, the snare slices 3 dB under the rest of the break" do
    MB::Sound::Mastering::Targeting.last = nil
    MB::Sound.render(tmp_path('n.flac'), bars: 0.1) { MB::Sound.memory_card }
    expect(MB::Sound::Mastering::Targeting.last).to be_nil
    MB::Sound.render(tmp_path('m.flac'), bars: 0.1) { MB::Sound.memory_card(vinyl: true) }
    expect(MB::Sound::Mastering::Targeting.last.preset).to eq(:vinyl)

    snare = MB::Sound.memory_card_chops(snare: -3.db)[:a]
    plain = MB::Sound.memory_card_chops[:a]
    keys = MB::Sound::MEMORY_CARD_SNARES.map { |n| MB::Sound.chop(n).events[0].value }
    vels = snare.events.group_by { |e| keys.include?(e.value) }.transform_values { |es| es.map(&:velocity).uniq }
    expect(vels[true].map { |v| v.round(4) }).to eq([(0.75 * -3.db.to_f).round(4)])
    expect(vels[false]).to eq([0.75])
    expect(plain.events.map(&:velocity).uniq).to eq([0.75])
  end

  it 'chops by slice name, with pitched slices: keys of the break with pitch marks, three semitones up' do
    brk = MB::Sound.memory_card_break
    clip = MB::Sound.chop(:k, MB::Sound::T, [:s, 2], MB::Sound::R, :rev)
    keys = brk.chop(:k, :s, brk[:s2].rev).events.map(&:value)
    expect(clip.events.map(&:value)).to eq(keys)
    expect(clip.events.map(&:pitch)).to eq([3.0, 5.0, 3.0])
    expect(clip.transpose(2).events.map(&:value)).to eq(keys)
  end
end

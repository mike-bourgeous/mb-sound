RSpec.describe('bin/synths/skylark_junction.rb') do
  before(:all) do
    require File.expand_path('../../../bin/synths/skylark_junction.rb', __dir__)
    @record = MB::Sound.nev_record
    @map = MB::Sound.nev_sampler(@record)
  end

  after { MB::Sound.rewind }

  let(:record_bpm) { 165 / 2 ** (3 / 12.0) }

  it 'presses two bars of a break at the record tempo' do
    expect(@record.length).to eq((48000 * 60.0 / record_bpm * 8).round)
    expect(@record.abs.max).to be_between(0.3, 1.0)

    # A kick on the first 16th, the snare on the fifth
    step = 48000 * 60.0 / record_bpm / 4
    expect(peak_db(@record[0...(step / 2).round])).to be > -6
    expect(peak_db(@record[(4 * step).round...(4.5 * step).round])).to be > -10
  end

  it 'maps 11 slices onto 11-semitone zones, played in tempo three semitones above each root' do
    keys = MB::Sound.nev_slice_keys
    expect(keys.keys).to eq([:k, :h, :s, :sk, :g, :kk, :s2, :k2, :s3, :full, :rev])
    expect(keys.values.map(&:number)).to eq((0...11).map { |i| 6 + 11 * i })
    expect(@map.zones.length).to eq(11)
    expect(@map.zones.map { |lo, hi, _| [lo, hi] }).to eq((0...11).map { |i| [2 + 11 * i, 13 + 11 * i] })
  end

  it 'plays a slice from its key: the record at 165 BPM, 12 bits' do
    key = MB::Sound.nev_slice_keys[:full].number
    out = render_patch(MB::Sound.nev_breaks_voice(note_stream([key, 0, 3, 0.75]), map: @map, grit: 0), 3.5)[0]
    bar = 48000 * 240 / 165.0
    expect(peak_db(seconds(out, 0, 0.02))).to be > -10 # the first kick
    # A kick again on beat 1 of the second bar (the record's beats land on the song's)
    second = out[(bar - 200).round...(bar + 0.02 * 48000).round]
    expect(peak_db(second)).to be > -10
    expect(rms_db(out[(2 * bar + 4800).round..])).to be < -90 # a two-bar slice, over

    # 12-bit slices: every table sample is a multiple of 1/2048
    data = Numo::DFloat.cast(@map.zones[3][2].frames)
    expect(data.length).to be > 1000
    expect(((data * 2048) - (data * 2048).round).abs.max).to be < 1e-3
  end

  it 'cuts the last slice with each new one (one voice)' do
    keys = MB::Sound.nev_slice_keys
    one = render_patch(MB::Sound.nev_breaks_voice(note_stream([keys[:full].number, 0, 1, 0.75]), map: @map), 1)[0]
    cut = render_patch(MB::Sound.nev_breaks_voice(note_stream([keys[:full].number, 0, 0.5, 0.75], [keys[:h].number, 0.5, 0.6, 0.75]), map: @map), 1)[0]
    expect(seconds(cut, 0, 0.49)).to eq(seconds(one, 0, 0.49))
    expect(rms_db(seconds(cut, 0.7, 1.0))).to be < rms_db(seconds(one, 0.7, 1.0)) - 20
  end

  it 'plays the melodic patches' do
    {
      sub: [MB::Sound.nev_sub_voice(note_stream([MB::Sound::D2.number, 0, 1])), -20],
      reese: [MB::Sound.nev_reese_voice(note_stream([MB::Sound::D2.number, 0, 1])), -25],
      rhodes: [MB::Sound.nev_rhodes_voice(note_stream([MB::Sound::F3.number, 0, 1], [MB::Sound::A3.number, 0, 1])), -35],
      pad: [MB::Sound.nev_pad_voice(note_stream([MB::Sound::F4.number, 0, 2])), -50],
      flute: [MB::Sound.nev_flute_voice(note_stream([MB::Sound::A4.number, 0, 1])), -35],
    }.each do |name, (graph, floor)|
      out = render_patch(graph, 2)
      expect(peak_db(out[0])).to be_between(floor, 0), "#{name}: #{peak_db(out[0]).round(1)} dB"
    end

    sub = render_patch(MB::Sound.nev_sub_voice(note_stream([MB::Sound::D2.number, 0, 1])), 1)[0]
    expect(peak_hz(seconds(sub, 0.2, 0.9), 20, 200)).to be_within(1.5).of(MB::Sound::D2.frequency)
  end

  it 'plays the ride and shaker from GM notes, highpassed' do
    out = render_patch(MB::Sound.nev_perc(note_stream([51, 0, 0.1, 1.0], [70, 0.5, 0.6, 1.0])), 1)[0]
    expect(peak_db(seconds(out, 0, 0.4))).to be > -30
    expect(peak_db(seconds(out, 0.5, 0.7))).to be > -40
    expect(band_share(out, 0, 150)).to be < 0.01
  end

  it 'renders the breaks from a MIDI file with -p breaks' do
    out_file = tmp_path('nev_breaks.flac')
    out, status = fork_script('bin/synths/skylark_junction.rb', '-q', '-p', 'breaks', '-c', '3000', 'spec/test_data/c_major.mid', out_file)
    expect(status).to be_success, out
    expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.01
  end
end

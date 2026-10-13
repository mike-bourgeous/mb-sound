RSpec.describe('bin/synths/kaede_rowntree.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/kaede_rowntree.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'strikes a bowl at each note-on: its partials ring for seconds, beating, harder with velocity' do
    soft = render_patch(MB::Sound.kaede_bowl_voice(note_stream([MB::Sound::D3.number, 0, 0.2, 0.3]), space: 0), 6)[0]
    hard = render_patch(MB::Sound.kaede_bowl_voice(note_stream([MB::Sound::D3.number, 0, 0.2, 1.0]), space: 0), 6)[0]
    expect(peak_hz(seconds(hard, 0.5, 5.5), 60, 2000)).to be_within(2).of(MB::Sound::D3.frequency)
    expect(rms_db(seconds(hard, 5, 6))).to be > rms_db(seconds(hard, 0, 1)) - 20 # still ringing
    expect(rms_db(hard)).to be_within(0.5).of(rms_db(soft) + 20 * Math.log10(1.0 / 0.3))

    # The doublet beats 0.7 apart: the fundamental's envelope swells and fades
    # about every 1.4 s
    env = (0...12).map { |i| rms_db(seconds(hard, 0.5 + i * 0.4, 0.7 + i * 0.4)) }
    expect(env.max - env.min).to be > 3
  end

  it 'plays the rin higher and brighter in its room' do
    rin = render_patch(MB::Sound.kaede_rin_voice(note_stream([MB::Sound::G4.number, 0, 0.2, 1.0])), 3)
    expect(rin.length).to eq(2)
    expect(peak_hz(seconds(rin[0], 0.5, 2.5), 200, 4000)).to be_within(4).of(MB::Sound::G4.frequency)
  end

  it 'strikes the gong at 55 Hz from D2, following other notes, its shimmer swelling in' do
    d2 = render_patch(MB::Sound.kaede_gong_voice(note_stream([MB::Sound::D2.number, 0, 4, 1.0]), space: 0), 4)[0]
    expect(peak_hz(seconds(d2, 3, 4), 40, 70)).to be_within(1.5).of(55) # (5% sharp at the stroke, gliding down over 4 s)
    d3 = render_patch(MB::Sound.kaede_gong_voice(note_stream([MB::Sound::D3.number, 0, 4, 1.0]), space: 0), 4)[0]
    expect(peak_hz(seconds(d3, 3, 4), 90, 130)).to be_within(1.5).of(110)

    expect(band_share(seconds(d2, 2.5, 3.5), 2000, 8000)).to be > band_share(seconds(d2, 0, 0.5), 2000, 8000) * 3
  end

  it 'wears the e-piano and harp with the tape' do
    notes = -> { note_stream([MB::Sound::A4.number, 0, 0.5], [MB::Sound::D5.number, 0.5, 1]) }
    new = render_patch(MB::Sound.kaede_epiano_voice(notes.(), wear: 0, space: 0), 2)[0]
    old = render_patch(MB::Sound.kaede_epiano_voice(notes.(), wear: 1, space: 0), 2)[0]
    expect(peak_db(new)).to be > -40
    expect((old - new).abs.max).to be > 1e-3

    harp = render_patch(MB::Sound.kaede_harp_voice(notes.(), wear: 0.5), 2)
    expect(peak_db(harp[0])).to be > -50
  end

  it 'drones on the note: root, fifth, and octave' do
    out = render_patch(MB::Sound.kaede_drone_voice(note_stream([MB::Sound::D2.number, 0, 6])), 6)
    expect(out.length).to eq(2)
    x = seconds(out[0], 3, 6)
    expect(peak_hz(x, 50, 90)).to be_within(1).of(MB::Sound::D2.frequency)
    expect(peak_hz(x, 100, 120)).to be_within(1).of(MB::Sound::A2.frequency)
    expect(peak_hz(x, 140, 160)).to be_within(1).of(MB::Sound::D3.frequency)
    expect(rms_db(seconds(out[0], 0, 0.3))).to be < rms_db(seconds(out[0], 3, 4)) - 10 # a slow swell
  end

  it 'tips the rain stick from right to left over the note' do
    l, r = render_patch(MB::Sound.kaede_rainstick_voice(note_stream([MB::Sound::D5.number, 0, 8])), 9)
    early = rms_db(seconds(r, 1, 2)) - rms_db(seconds(l, 1, 2))
    late = rms_db(seconds(r, 6, 7)) - rms_db(seconds(l, 6, 7))
    expect(early).to be > 3
    expect(late).to be < -3
  end

  it 'renders the gong from a MIDI file with -p gong' do
    out_file = tmp_path('kaede_gong.flac')
    out, status = fork_script('bin/synths/kaede_rowntree.rb', '-q', '-p', 'gong', '-s', '0.2', 'spec/test_data/c_major.mid', out_file)
    expect(status).to be_success, out
    expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.01
  end
end

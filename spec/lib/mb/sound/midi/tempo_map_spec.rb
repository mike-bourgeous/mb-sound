require_relative '../../../../support/midi_writer'

RSpec.describe(MB::Sound::MIDI::TempoMap) do
  it 'converts pulses to exact seconds across tempo changes, and back' do
    map = described_class.new([[960, 1_000_000], [0, 500_000], [2880, 250_000]], ppqn: 960)
    expect(map.seconds(0)).to eq(0r)
    expect(map.seconds(960)).to eq(1/2r)
    expect(map.seconds(1920)).to eq(3/2r)
    expect(map.seconds(2880 + 480)).to eq(5/2r + 1/8r)
    expect([0, 960, 1500, 1920, 3000].map { |p| map.pulses(map.seconds(p)) }).to eq([0, 960, 1500, 1920, 3000])
    expect(map.bpm_at(1000)).to eq(60.0)
    expect(map).to be_changes
  end

  it 'starts at 120 BPM before the first tempo and in files without one; the last tempo on a pulse wins' do
    expect(described_class.new([], ppqn: 480).seconds(480)).to eq(1/2r)
    map = described_class.new([[960, 600_000], [960, 400_000]], ppqn: 960)
    expect(map.seconds(960)).to eq(1/2r)
    expect(map.seconds(1920)).to eq(1/2r + 2/5r)
  end

  it 'makes FileSource play a rubato file at its recorded times (tempo events of every track)' do
    path = MidiWriter.rubato(tmp_path('rubato.mid'))
    src = MB::Sound::MIDI::FileSource.new(path)
    bpms = [100, 80, 60, 120, 90, 72, 140, 100]
    expected = bpms.each_with_index.map { |_b, i| bpms[0...i].sum { |b| Rational(MIDI::Tempo.bpm_to_mpq(b).round, 1_000_000) } }
    expect(src.events.select(&:note_on?).map(&:time)).to eq(expected)
    # The constant map keeps the first tempo for the whole file
    const = MB::Sound::MIDI::FileSource.new(path, tempo_map: MB::Sound::MIDI::FileSource::ConstantTempo.from_sequence(src.midi_file.seq))
    expect(const.events.select(&:note_on?).map(&:time)).to eq((0...8).map { |i| i * 3/5r })
    expect(src.midi_file.duration).to be_within(1e-9).of(src.midi_file.tempo_map.seconds(7620).to_f)
  end
end

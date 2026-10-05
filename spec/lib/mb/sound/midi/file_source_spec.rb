RSpec.describe(MB::Sound::MIDI::FileSource) do
  let(:files) { Dir['spec/test_data/*.mid'].sort }

  # Channel and sysex events from a MIDIFile, as [seconds, bytes].
  def midi_file_events(m)
    m.events.reject { |e| e.is_a?(::MIDI::MetaEvent) }.map { |e| [m.send(:pulse_time, e.time_from_start), e.data_as_bytes.pack('C*')] }
  end

  # Reads +src+ in +step+-second chunks up to +stop+ seconds.
  def read_all(src, step: 0.01r, stop: 12)
    out = []
    t = src.position
    while t < stop
      out.concat(src.read(t, t + step))
      t += step
    end
    out
  end

  it 'has the same events at the same times as MIDIFile for every test file' do
    files.each do |f|
      m = MB::Sound::MIDI::MIDIFile.new(f)
      src = MB::Sound::MIDI::FileSource.new(f)
      expected = midi_file_events(m)

      expect(src.events.length).to eq(expected.length), "#{f}: event count"
      src.events.zip(expected).each do |e, (t, bytes)|
        expect(e.bytes).to eq(bytes.b), "#{f}: bytes of #{e}"
        expect(e.time).to be_a(Rational)
        expect(e.time.to_f).to be_within(1e-9).of(t), "#{f}: time of #{e}"
      end

      expect(src.music_end.to_f).to be_within(1e-9).of(m.music_end), f unless expected.empty?
      expect(src.duration.to_f).to be_within(1e-9).of(m.duration), f
    end
  end

  it 'reads the same events in chunks as all at once' do
    files.each do |f|
      src = MB::Sound::MIDI::FileSource.new(f)
      events = read_all(src, step: 1/48r)
      expect(events).to eq(MB::Sound::MIDI::FileSource.new(f).read(0, 12)), f
    end
  end

  it 'reads every event of files with balanced notes' do
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/c_major.mid')
    expect(read_all(src)).to eq(src.events)
  end

  it 'leaves out note-offs for notes that are not sounding' do
    # This file has note-offs without note-ons, and repeated note-offs
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/fast_note_velocity.mid')
    events = src.read(0, 12)
    expect(events.length).to be < src.events.length
    expect(events.count(&:note_on?)).to eq(src.events.count(&:note_on?))
    expect(events.count(&:note_off?)).to eq(events.count(&:note_on?))
  end

  it 'reads events in [from, to)' do
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/c_major.mid')
    t = src.events[2].time
    expect(src.read(0, t)).to eq(src.events[0..1])
    expect(src.read(t, t + 1/1000r).first).to eq(src.events[2])
  end

  it 'gives the same notes as MIDIFile#notes for a file without pedals' do
    m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/c_major.mid')
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/c_major.mid')

    on = {}
    notes = []
    read_all(src).each do |e|
      if e.note_on?
        on[e.note] = e
      elsif e.note_off?
        start = on.delete(e.note)
        notes << [e.channel, e.note, start.raw, start.time.to_f, e.time.to_f]
      end
    end

    expected = m.notes.map { |n| [n[:channel], n[:number], n[:on_velocity], n[:on_time], n[:off_time]] }
    expect(notes.sort.map { |n| n.map { |v| v.is_a?(Float) ? v.round(9) : v } }).to eq(expected.sort.map { |n| n.map { |v| v.is_a?(Float) ? v.round(9) : v } })
  end

  describe '#ended? and #music_end' do
    it 'ends once the last event has been read' do
      src = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid')
      last = src.events.last.time
      src.read(0, last)
      expect(src.ended?).to eq(false)
      expect(src.read(last, last + 1/1000r)).to eq([src.events.last])
      expect(src.ended?).to eq(true)
    end

    it 'reports music_end in stream time' do
      src = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid')
      src.read(0, 5)
      src.restart
      expect(src.music_end).to eq(5 + src.events.last.time)
      expect(src.ended?).to eq(false)
    end
  end

  describe '#seek and #restart' do
    let(:src) { MB::Sound::MIDI::FileSource.new('spec/test_data/c_major.mid') }

    it 'restarts from the beginning at the current stream time' do
      first = src.read(0, 1)
      gen = src.generation
      src.restart
      expect(src.generation).to eq(gen + 1)
      again = src.read(1, 2)
      expect(again.map(&:bytes)).to eq(first.map(&:bytes))
      expect(again.map(&:time)).to eq(first.map { |e| e.time + 1 })
    end

    it 'seeks within the file' do
      src.read(0, 1/2r)
      src.seek(2)
      events = src.read(1/2r, 1)

      # The note sounding at the seek gets a note-off there
      expect(events.first).to have_attributes(type: :note_off, note: 28, time: 1/2r)

      expected = src.events.select { |e| e.time >= 2 && e.time < 5/2r }
      expect(events.drop(1).map(&:bytes)).to eq(expected.map(&:bytes))
      expect(events.drop(1).map(&:time)).to eq(expected.map { |e| e.time - 3/2r })
    end

    it 'delays the start with a negative seek' do
      src.seek(-1)
      expect(src.read(0, 1)).to eq([])
      expect(src.read(1, 2).first.time).to eq(1 + src.events.first.time)
    end

    it 'can be reused by restarting after it ended (GH #67)' do
      a = read_all(src, stop: 10)
      expect(src.ended?).to eq(true)
      src.restart
      expect(src.ended?).to eq(false)
      b = read_all(src, stop: 20)
      expect(b.map(&:bytes)).to eq(a.map(&:bytes))
    end
  end

  describe 'looping' do
    it 'repeats every duration' do
      src = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid', loop: true)
      events = read_all(src, step: 1/7r, stop: 6)
      n = src.events.length
      expect(events.length).to eq(3 * n)
      expect(events.map(&:time)).to eq([0, 2, 4].flat_map { |o| src.events.map { |e| e.time + o } })
      expect(src.ended?).to eq(false)
      expect(src.music_end).to eq(nil)
    end

    it 'refuses to loop a file with no length' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/empty.mid')
      allow(m.seq.tracks.first.events.last).to receive(:time_from_start).and_return(0)
      expect { MB::Sound::MIDI::FileSource.new(m, loop: true) }.to raise_error(ArgumentError, /no length/)
    end
  end

  it 'accepts a tempo map' do
    tempo = MB::Sound::MIDI::FileSource::ConstantTempo.new(microseconds_per_quarter: 1_000_000, ppqn: 960)
    src = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid', tempo_map: tempo)
    normal = MB::Sound::MIDI::FileSource.new('spec/test_data/c2_sustain.mid')
    expect(src.events.map(&:time)).to eq(normal.events.map { |e| e.time * 2 })
  end
end

RSpec.describe(MB::Sound::MIDI::Stream) do
  let(:ev) { MB::Sound::MIDI::Event }
  let(:file) { 'spec/test_data/c_major.mid' }

  # Reads +reader+ in buffers of +count+ samples at +rate+ until +seconds+,
  # returning [event, sample index] pairs.
  def read_at_rate(reader, rate, count, seconds)
    out = []
    pos = 0
    while pos < seconds * rate
      from = Rational(pos, rate)
      reader.events(from, Rational(pos + count, rate)).each do |e|
        out << [e, pos + ((e.time - from) * rate).floor]
      end
      pos += count
    end
    out
  end

  describe 'readers' do
    it 'gives every reader the same events, reading the source once, at different rates and buffer sizes' do
      src = MIDIListSource.new(MB::Sound::MIDI::FileSource.new(file).events)
      stream = MB::Sound::MIDI::Stream.new(src)
      readers = [[48000, 800], [44100, 441], [96000, 1000], [48000, 13]].map { |rate, count| [stream.reader, rate, count] }

      results = Array.new(readers.length) { [] }
      # Interleave readers buffer by buffer like a Session would
      positions = Array.new(readers.length, 0)
      until positions.each_with_index.all? { |p, i| p >= 7 * readers[i][1] }
        readers.each_with_index do |(r, rate, count), i|
          next if positions[i] >= 7 * rate
          from = Rational(positions[i], rate)
          results[i].concat(r.events(from, Rational(positions[i] + count, rate)))
          positions[i] += count
        end
      end

      expected = MB::Sound::MIDI::FileSource.new(file).read(0, 7)
      results.each { |res| expect(res).to eq(expected) }
      expect(stream.pending_count).to eq(0)
    end

    it 'lands events on the right sample for each rate' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.note_on(60, time: 1/3r), ev.note_off(60, time: 1)))
      a = stream.reader
      b = stream.reader
      expect(read_at_rate(a, 48000, 800, 2).map(&:last)).to eq([16000, 48000])
      expect(read_at_rate(b, 44100, 512, 2).map(&:last)).to eq([14700, 44100])
    end

    it 'drops events once every reader has passed them' do
      src = MIDIListSource.new(ev.note_on(60, time: 0.1), ev.note_off(60, time: 0.2), ev.cc(1, 0.5, time: 0.3))
      stream = MB::Sound::MIDI::Stream.new(src)
      a = stream.reader
      b = stream.reader

      expect(a.events(0, 1/4r).length).to eq(2)
      expect(stream.pending_count).to eq(2)
      expect(b.events(0, 1/8r).length).to eq(1)
      expect(stream.pending_count).to eq(1)
      expect(a.next(1/4r).map(&:type)).to eq([:cc])
      expect(stream.pending_count).to eq(2)
      expect(b.events(1/8r, 1).map(&:type)).to eq([:note_off, :cc])
      expect(stream.pending_count).to eq(0)
      expect(src.reads).to eq(3) # [0, 1/4), [1/4, 1/2), [1/2, 1)
    end

    it 'stops keeping events for a closed reader' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.note_on(60, time: 0.1)))
      a = stream.reader
      b = stream.reader
      a.events(0, 1)
      expect(stream.pending_count).to eq(1)
      b.close
      expect(stream.pending_count).to eq(0)
    end

    it 'starts new readers at the slowest reader' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.note_on(60, time: 0.1), ev.note_on(62, time: 0.3)))
      a = stream.reader
      b = stream.reader
      a.events(0, 1/2r)
      b.events(0, 1/5r)
      c = stream.reader
      expect(c.cursor).to eq(1/5r)
      expect(c.next(1).map(&:note)).to eq([62])
      expect(stream.reader(at: 2).cursor).to eq(2)
    end

    it 'skips events when reading from after the cursor' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.cc(1, 0, time: 0.1), ev.cc(1, 1, time: 0.3)))
      r = stream.reader
      expect(r.events(1/4r, 1/2r).map(&:value)).to eq([1.0])
    end

    it 'refuses to read events twice' do
      r = MB::Sound::MIDI::Stream.new(MIDIListSource.new).reader
      r.events(0, 1)
      expect { r.events(1/2r, 1) }.to raise_error(ArgumentError, /already read/)
      expect { r.events(2, 1) }.to raise_error(ArgumentError, /before it starts/)
    end

    it 'moves late events from a live source to where they arrived' do
      late = Class.new do
        include MB::Sound::MIDI::Source
        def read_events(from, _to)
          from == 0 ? [] : [MB::Sound::MIDI::Event.cc(1, 1, time: from - 1/100r), MB::Sound::MIDI::Event.cc(2, 1, time: from + 1/1000r)]
        end
      end

      r = MB::Sound::MIDI::Stream.new(late.new).reader
      expect(r.next(1/10r)).to eq([])
      expect(r.next(1/10r).map { |e| [e.note, e.time] }).to eq([[1, 1/10r], [2, 101/1000r]])
    end
  end

  describe '#ended?' do
    it 'ends for a reader once the source ended and the reader has read every event' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.note_on(60, time: 0.5)))
      a = stream.reader
      b = stream.reader
      a.events(0, 1)
      expect(a.ended?).to eq(true)
      expect(b.ended?).to eq(false)
      expect(stream.ended?).to eq(false)
      b.events(0, 1)
      expect(b.ended?).to eq(true)
      expect(stream.ended?).to eq(true)
      expect(a.music_end).to eq(1/2r)
    end
  end

  describe '#restart and #seek' do
    it 'jumps the content for every reader and changes the generation' do
      stream = MB::Sound::MIDI::Stream.for(file)
      r = stream.reader
      first = r.events(0, 1)
      gen = r.generation
      stream.restart
      expect(r.generation).to eq(gen + 1)
      again = r.events(1, 2)
      expect(again.map(&:bytes)).to eq(first.map(&:bytes))

      stream.seek(0)
      expect(r.events(2, 3).map(&:bytes)).to eq(first.map(&:bytes))
    end

    it 'restarts the root source from a transformed stream' do
      stream = MB::Sound::MIDI::Stream.for(file)
      view = stream.channel(0)
      r = view.reader
      first = r.events(0, 1)
      view.restart
      expect(r.events(1, 2).map(&:bytes)).to eq(first.map(&:bytes))
    end
  end

  describe '.for' do
    it 'makes streams from sources, clips, files, and streams' do
      clip = MB::Sound::C4.n4
      expect(MB::Sound::MIDI::Stream.for(clip).source).to be_a(MB::Sound::MIDI::ClipSource)
      expect(MB::Sound::MIDI::Stream.for(file).source).to be_a(MB::Sound::MIDI::FileSource)
      expect(MB::Sound::MIDI::Stream.for(MB::Sound::MIDI::MIDIFile.new(file)).source).to be_a(MB::Sound::MIDI::FileSource)
      s = MB::Sound::MIDI::Stream.for(clip)
      expect(MB::Sound::MIDI::Stream.for(s)).to equal(s)
      expect { MB::Sound::MIDI::Stream.for(42) }.to raise_error(ArgumentError)
    end
  end

  describe 'graph traversal' do
    it 'lists its source so a Session can find a clip timeline' do
      stream = MB::Sound::MIDI::Stream.for(MB::Sound::C4.n4.loop).channel(0).transpose(12)
      graph = stream.graph
      expect(graph.grep(MB::Sound::Sequence::TimelineNode).length).to eq(1)
      expect(graph.grep(MB::Sound::MIDI::Stream).length).to eq(3)
      expect(stream.graphviz).to include('MIDI transpose(12)')
      expect(stream.graphviz).to include('MIDI Clip')
    end

    it 'has no sample rate, so sample rate changes pass it by' do
      stream = MB::Sound::MIDI::Stream.for(file)
      expect(stream).not_to respond_to(:sample_rate)
      expect(stream).not_to respond_to(:sample)
      expect(stream).not_to be_a(MB::Sound::GraphNode)
    end
  end

  describe 'bend range' do
    it 'adds the default bend range of 2 semitones to bend events' do
      r = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.bend(0.5, time: 0.1))).reader
      e = r.next(1).first
      expect(e.bend_range).to eq(2)
      expect(e.bend_semitones).to eq(1.0)
    end

    it 'follows RPN 0 per channel' do
      events = [
        ev.cc_raw(101, 0, channel: 1), ev.cc_raw(100, 0, channel: 1), ev.cc_raw(6, 12, channel: 1), ev.cc_raw(38, 50, channel: 1),
        ev.bend(1.0, channel: 1), ev.bend(1.0, channel: 0),
      ].each_with_index.map { |e, idx| e.at(Rational(idx, 100)) }
      bends = MB::Sound::MIDI::Stream.new(MIDIListSource.new(events)).reader.next(1).select(&:bend?)
      expect(bends.map(&:bend_range)).to eq([25/2r, 2])
      expect(bends.map(&:bend_semitones)).to eq([12.5, 2.0])
    end

    it 'ignores data entry for other parameters and after RPN null' do
      events = [
        ev.cc_raw(101, 0), ev.cc_raw(100, 1), ev.cc_raw(6, 12), # RPN 1 (fine tuning)
        ev.cc_raw(101, 0), ev.cc_raw(100, 0), ev.cc_raw(101, 127), ev.cc_raw(100, 127), ev.cc_raw(6, 7), # null
        ev.cc_raw(101, 0), ev.cc_raw(100, 0), ev.cc_raw(99, 0), ev.cc_raw(6, 9), # NRPN
        ev.bend(-1.0),
      ].each_with_index.map { |e, idx| e.at(Rational(idx, 100)) }
      bend = MB::Sound::MIDI::Stream.new(MIDIListSource.new(events)).reader.next(1).find(&:bend?)
      expect(bend.bend_semitones).to eq(-2.0)
    end

    it 'can start with another default range' do
      stream = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.bend(1.0)), bend_range: 12.st)
      expect(stream.reader.next(1).first.bend_semitones).to eq(12.0)
    end
  end

  describe '#advance' do
    let(:stream) { MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::FileSource.new(file)) }

    it 'adds a buffer of samples exactly' do
      expect(stream.advance(0r, 128, 48000.0)).to eq(Rational(128, 48000))
      expect(stream.advance(Rational(1, 3), 100, 44100.0)).to eq(Rational(1, 3) + Rational(100, 44100))
      expect(stream.advance(Rational(1, 3), 100, 44100.0)).to be_a(Rational)
    end

    it 'shares the result among readers at the same time' do
      a = stream.advance(Rational(5, 7), 128, 48000.0)
      b = stream.advance(Rational(5, 7), 128, 48000.0)
      expect(b).to equal(a)
    end

    it 'follows changes of time, count, and rate' do
      t = Rational(5, 7)
      a = stream.advance(t, 128, 48000.0)
      expect(stream.advance(a, 128, 48000.0)).to eq(t + Rational(256, 48000))
      expect(stream.advance(t, 64, 48000.0)).to eq(t + Rational(64, 48000))
      expect(stream.advance(t, 64, 96000.0)).to eq(t + Rational(64, 96000))
    end
  end

  it 'returns one frozen empty Array for reads without events' do
    stream = MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::FileSource.new(file))
    reader = stream.reader
    reader.events(0r, 0r)
    a = reader.events(100r, 101r)
    b = reader.events(101r, 102r)
    expect(a).to be_empty
    expect(a).to be_frozen
    expect(b).to equal(a)
  end
end

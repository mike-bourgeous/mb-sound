RSpec.describe(MB::Sound::MIDI::RealtimeReader) do
  it 'plays a MIDI file in real time, then returns nil' do
    reader = MB::Sound::MIDI::RealtimeReader.new('spec/test_data/poly_pressure.mid')
    expect(reader.file?).to eq(true)

    events = []
    start = MB::U.clock_now
    while (batch = reader.read)
      expect(batch).not_to be_empty
      events.concat(batch)
    end

    expected = MB::Sound::MIDI::FileSource.new('spec/test_data/poly_pressure.mid').events
    expect(events).to eq(expected)
    expect(MB::U.clock_now - start).to be >= expected.last.time.to_f
    expect(reader.read).to eq(nil)
  end

  it 'returns an empty Array with wait: false before events are due' do
    reader = MB::Sound::MIDI::RealtimeReader.new('spec/test_data/c2_sustain.mid')
    first = reader.source.events.first.time
    skip 'the first event is at 0' if first == 0
    expect(reader.read(wait: false)).to eq([])
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) { skip @jack_error if @jack_error }

    around(:each) do |example|
      old = ENV['MIDI_API']
      ENV['MIDI_API'] = 'jack'
      example.run
    ensure
      ENV['MIDI_API'] = old
    end

    it 'reads live MIDI from a source by name, leaving out realtime messages' do
      keyboard = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_rtkeys', nil, 'out')
      reader = nil
      expect { reader = MB::Sound::MIDI::RealtimeReader.new('mbspec_rtkeys') }.to output(/Reading MIDI from mbspec_rtkeys/).to_stdout
      expect(reader.file?).to eq(false)
      expect(reader.read(wait: false)).to eq([])

      sleep 0.05
      [[0xf8], [0x90, 60, 100], [0xb0, 1, 64]].each { |m| keyboard.send_bytes(m.pack('C*')) }

      events = []
      deadline = MB::U.clock_now + 2
      while events.length < 2 && MB::U.clock_now < deadline
        events.concat(reader.read(wait: false))
        sleep 0.005
      end

      expect(events.map(&:type)).to eq([:note_on, :cc])
      expect(events.map(&:raw)).to eq([100, 64])
    ensure
      reader&.close
      keyboard&.close
      MB::Sound::Jack.close
    end
  end
end

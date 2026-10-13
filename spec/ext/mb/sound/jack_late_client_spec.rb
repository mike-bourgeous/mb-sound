# A shared-client MIDI input whose JACK thread is late (FastAudio::
# JackMIDIInput#stall sleeps in its callbacks, like a thread the system
# didn't schedule in time), receiving from an outside client as in the MIDI
# specs.  An asynchronous server (jackd's default) then skips cycles for it,
# losing what arrived in them, and calls it twice for one cycle; the input
# drops the repeat instead of queueing its messages again.  A synchronous
# server (JackDummy's default) waits, so nothing is lost.  (2026-10-13,
# branch jack-flake-1: input_spec's read_raw example once read a note-off
# twice and lost the note-on in a full parallel run.)
RSpec.describe('JACK MIDI input with a late client', :aggregate_failures) do
  let(:fa) { MB::Sound::FastAudio }
  let(:client) { "mbspec_late#{rand(1 << 20)}" }

  before(:each) do
    skip @jack_error if @jack_error
    @opened = []
    @keyboard = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_late_keys', nil, 'out')
  end

  after(:each) do
    @opened.each(&:close)
    @keyboard&.close
    fa.jack_close
    MB::Sound::MIDI::Input.repeats_reported = nil
  end

  # Sends +count+ distinct note-ons 3-5 ms apart while +read+ polls, and
  # returns the note numbers read, in order.
  def send_notes(count, &read)
    got = []
    reader = Thread.new do
      deadline = MB::U.clock_now + 2
      while got.length < count && MB::U.clock_now < deadline
        got.concat(read.call)
        sleep 0.002
      end
    end
    count.times do |i|
      @keyboard.send_bytes([0x90, i, 100].pack('C*'))
      sleep 0.003 + 0.002 * (i % 2)
    end
    sleep 0.1
    reader.kill.join
    got.concat(read.call)
    got.map { |_, bytes| bytes.getbyte(1) }
  end

  def late_input
    inp = fa::JackMIDIInput.new(client, 'midi_in', 4096).tap { |m| @opened << m }
    expect(fa.jack_connect('mbspec_late_keys:out', inp.port_name)).to eq(true)
    sleep 0.05
    inp.stall(12000, 7) # 12 ms (over two 256-frame periods) every 7th callback
    inp
  end

  context 'with an asynchronous server' do
    before(:context) { @jack_error = JackDummy.start(sync: false) }
    after(:context) { JackDummy.stop }

    it 'receives the messages of a repeated cycle once' do
      inp = late_input
      notes = send_notes(96) { inp.read(false) }

      # The stall made the server skip and repeat cycles
      expect(inp.stats[:repeated]).to be > 0
      expect(fa.jack_info[:skipped_cycles]).to be > 0

      expect(notes.length).to be < 96 # the skipped cycles' messages are gone
      expect(notes).to eq(notes.uniq)
      expect(notes).to eq(notes.sort)
    end

    it 'warns once from MIDI::Input when JACK repeats a cycle' do
      inputs = Array.new(2) { MB::Sound::MIDI::Input.new(connect: 'mbspec_late_keys', api: :jack).tap { |i| @opened << i } }
      sleep 0.05
      inputs.each { |i| i.instance_variable_get(:@input).stall(12000, 7) }

      notes = nil
      expect {
        notes = send_notes(96) { inputs.flat_map(&:read_raw) }
      }.to output(/\AJACK ran a cycle twice for MIDI input .*midi_in.*`jackd --sync`[^\n]*\n\z/m).to_stderr
      expect(inputs.sum { |i| i.instance_variable_get(:@input).repeated }).to be > 0
      expect(notes.tally.values.max).to be <= 2 # once per input
    end
  end

  context 'with a synchronous server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    it 'loses nothing when the client is late' do
      inp = late_input
      notes = send_notes(96) { inp.read(false) }

      expect(notes).to eq((0...96).to_a)
      expect(inp.stats).to include(repeated: 0, dropped: 0)
      expect(fa.jack_info).to include(skipped_cycles: 0, repeated_cycles: 0)
    end
  end
end

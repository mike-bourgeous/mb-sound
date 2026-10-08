RSpec.describe(MB::Sound::MidiMethods, :aggregate_failures) do
  around(:each) do |ex|
    names = %w[
      AUDIO_BACKEND OUTPUT_TYPE OUTPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE MIDI_TIMING JACK_CLIENT_NAME
      AUDIO_PROFILE AUDIO_LATENCY AUDIO_BUFFER
    ]
    saved = names.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  after(:each) do
    MB::Sound.close_midi
    MB::Sound::Session.default.close
    MB::Sound.rewind
  end

  # A MIDI::Input stand-in (see LiveSource's spec) that never receives
  # anything.
  let(:fake_input) {
    double('MIDI::Input', read_raw: [], frame_times?: false, frame_rate: nil, close: nil, port: 'fake')
  }

  describe '#live_midi_latency' do
    before(:each) do
      ENV['OUTPUT_TYPE'] = 'device'
      ENV['AUDIO_BACKEND'] = 'null' # miniaudio's null sound card
    end

    it 'switches the background session to the :low profile' do
      expect { expect(MB::Sound.live_midi_latency).to eq(:low) }.to output(/:low latency profile/).to_stderr
      expect(MB::Sound::Session.default.output.profile).to eq(:low)
      expect(MB::Sound::Session.output_chosen?).to eq(false)
      expect { expect(MB::Sound.live_midi_latency).to eq(:low) }.not_to output.to_stderr
    end

    it 'replaces an automatic output that was already opened' do
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
      expect(MB::Sound.live_midi_latency(quiet: true)).to eq(:low)
      expect(MB::Sound::Session.default.output.profile).to eq(:low)
    end

    it 'leaves a profile chosen with AUDIO_PROFILE (set by -L and profile: in scripts)' do
      ENV['AUDIO_PROFILE'] = 'safe'
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output.profile).to eq(:safe)
    end

    it 'leaves a profile chosen with #latency or an output given to #use_output' do
      MB::Sound.latency(:default)
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output.profile).to eq(:default)

      out = MB::Sound::NullOutput.new(channels: 2)
      MB::Sound.use_output(out)
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output).to equal(out)

      # Back to the automatic output
      MB::Sound.use_output(nil)
      expect(MB::Sound.live_midi_latency(quiet: true)).to eq(:low)
    end

    it 'gives a hint instead of restarting a session with players or master effects' do
      MB::Sound.bg(220.hz.sine)
      expect { expect(MB::Sound.live_midi_latency).to eq(nil) }.to output(/`latency :low`/).to_stderr
      MB::Sound.panic
      MB::Sound::Session.default.close

      MB::Sound.master { |mix| mix.softclip }
      expect { expect(MB::Sound.live_midi_latency).to eq(nil) }.to output(/`latency :low`/).to_stderr
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
    end

    it 'does nothing for outputs other than the sound card' do
      ENV['OUTPUT_TYPE'] = 'null'
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output).to be_a(MB::Sound::NullOutput)
    end
  end

  describe '#midi' do
    before(:each) do
      ENV['OUTPUT_TYPE'] = 'device'
      ENV['AUDIO_BACKEND'] = 'null'
      allow(MB::Sound::MIDI::Input).to receive(:new).and_return(fake_input)
    end

    it 'is a Notes on a cached live stream that follows the session output, switched to :low' do
      midi = nil
      expect { midi = MB::Sound.midi }.to output(/:low latency profile/).to_stderr
      expect(midi).to be_a(MB::Sound::Notes)
      expect(MB::Sound.midi).to equal(midi)
      expect(MB::Sound.midi_stream).to equal(midi.stream)

      source = midi.stream.source
      expect(source).to be_a(MB::Sound::MIDI::LiveSource)
      expect(source.timing).to eq(:exact)
      expect(source.output).to equal(MB::Sound::Session.default.output)
      expect(source.output.profile).to eq(:low)
    end

    it 'applies the sustain pedals unless sustain: false, which is another Notes on the same input' do
      midi = MB::Sound.midi
      expect(midi.sustain?).to eq(true)
      dry = MB::Sound.midi(sustain: false)
      expect(dry.sustain?).to eq(false)
      expect(dry).not_to equal(midi)
      expect(MB::Sound.midi(sustain: false)).to equal(dry)
      expect(dry.stream).to equal(midi.stream)

      MB::Sound.close_midi
      expect(dry.stream.source).to be_closed
    end

    it 'follows the output when the session switches outputs' do
      midi = MB::Sound.midi
      MB::Sound.latency(:safe)
      expect(midi.stream.source.output).to equal(MB::Sound::Session.default.output)
      expect(midi.stream.source.output.profile).to eq(:safe)
    end

    it 'opens a new input after #close_midi' do
      midi = MB::Sound.midi
      MB::Sound.close_midi
      expect(midi.stream.source).to be_closed
      expect(MB::Sound.midi).not_to equal(midi)
    end

    it 'leaves the output alone if the input fails to open' do
      allow(MB::Sound::MIDI::Input).to receive(:new).and_raise(MB::Sound::FastMIDI::Error, 'no MIDI')
      expect { MB::Sound.midi }.to raise_error(MB::Sound::FastMIDI::Error)
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
    end

    it 'makes synths with Notes#synth and Synth.new' do
      expect(MB::Sound.midi.synth(voices: 2) { |v| v.hz.saw * v.amp_env }).to be_a(MB::Sound::Synth)
      expect(MB::Sound::Synth.new(MB::Sound.midi) { |v| v.gate }).to be_a(MB::Sound::Synth)
    end
  end

  describe '#midi_file' do
    it 'returns a Notes playing the file, or the result of a block given one' do
      notes = MB::Sound.midi_file('spec/test_data/c2_sustain.mid')
      expect(notes).to be_a(MB::Sound::Notes)
      expect(notes.stream.source).to be_a(MB::Sound::MIDI::FileSource)
      expect(notes.stream.source.looping?).to eq(false)
      expect(notes.sustain?).to eq(true)
      expect(MB::Sound.midi_file('spec/test_data/c2_sustain.mid', sustain: false).sustain?).to eq(false)

      gate = MB::Sound.midi_file('spec/test_data/c2_sustain.mid', loop: true) { |midi|
        expect(midi.stream.source.looping?).to eq(true)
        midi.gate
      }
      expect(gate).to be_a(MB::Sound::GraphNode)
      expect(gate.sample(48000).max).to eq(1)
    end

    it 'plays as a mono voice to the end of the file' do
      midi = MB::Sound.midi_file('spec/test_data/c2_sustain.mid')
      graph = midi.hz.saw * midi.amp_env(0.001, 0.1, 0.5, 0.05)
      peak = 0
      100.times do
        buf = graph.sample(4800)
        break if buf.nil?
        peak = [peak, buf.abs.max].max
      end
      expect(peak).to be > 0.1
      expect(graph.sample(4800)).to eq(nil)
    end

    it 'refuses files that are not MIDI files' do
      expect { MB::Sound.midi_file('spec/test_data/make_arp_a7.rb') }.to raise_error(ArgumentError, /make_arp_a7.rb is not a MIDI file/)
    end
  end

  describe '#synth' do
    it 'builds a Synth from a Notes, a filename, a clip, or a stream' do
      notes = MB::Sound::Notes.new('spec/test_data/c2_sustain.mid')
      [notes, 'spec/test_data/c2_sustain.mid', MB::Sound.seq(MB::Sound::C3).n8, notes.stream].each do |source|
        s = MB::Sound.synth(source, voices: 2, spares: 1) { |v| v.hz.saw * v.amp_env }
        expect(s).to be_a(MB::Sound::Synth)
        expect(s.voices).to eq(2)
        expect(s.lanes.length).to eq(3)
      end
    end

    it 'has 8 voices by default and passes options to Synth.new' do
      s = MB::Sound.synth('spec/test_data/c_major.mid', seed: 5, controls: [:volume]) { |v, i| v.hz * v.env }
      expect(s.voices).to eq(8)
      expect(s.seed).to eq(5)
      expect(s.output_controls).to eq([:volume])

      mono = MB::Sound.synth('spec/test_data/c_major.mid', voices: 1) { |v| v.hz * v.env }
      expect(mono).to be_mono
    end

    it 'plays a MIDI file to the end' do
      s = MB::Sound.synth('spec/test_data/c2_sustain.mid', voices: 2, tail: 0) { |v| v.hz.saw * v.amp_env(0.001, 0.1, 0.5, 0.05) }
      peak = 0
      200.times do
        buf = s.sample(4800)
        break if buf.nil?
        peak = [peak, buf.abs.max].max
      end
      expect(peak).to be > 0.1
      expect(s.ended?).to eq(true)
    end

    it 'reads live MIDI (the console midi) without a source' do
      ENV['OUTPUT_TYPE'] = 'null'
      allow(MB::Sound::MIDI::Input).to receive(:new).and_return(fake_input)
      notes = MB::Sound.midi
      expect(MB::Sound::Synth).to receive(:new).with(notes, voices: 2).and_call_original
      expect(MB::Sound.synth(voices: 2) { |v| v.hz.saw * v.amp_env }).to be_a(MB::Sound::Synth)
    end

    it 'requires a block' do
      expect { MB::Sound.synth('spec/test_data/c2_sustain.mid') }.to raise_error(ArgumentError, /block/)
    end
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    before(:each) do
      skip @jack_error if @jack_error
      ENV['OUTPUT_TYPE'] = 'null'
      ENV['JACK_CLIENT_NAME'] = "mbspec_console#{rand(1 << 20)}"
    end

    after(:each) do
      MB::Sound.close_midi
      MB::Sound::Jack.close
    end

    it 'plays notes sent to a port given by name' do
      ENV['MIDI_TIMING'] = 'asap'
      keyboard = MB::Sound::FastMIDI::Output.new(:jack, "#{ENV['JACK_CLIENT_NAME']}_keys", nil, 'out')
      midi = MB::Sound.midi("#{ENV['JACK_CLIENT_NAME']}_keys")
      expect(midi.stream.source.input.api).to eq(:jack)
      expect(midi.stream.source.input.connections.join).to include("#{ENV['JACK_CLIENT_NAME']}_keys")

      gate = midi.gate
      number = midi.number
      mod = midi.mod(smooth: false) # the value as sent, not its 10 ms glide
      sleep 0.1
      keyboard.send_bytes([0xb0, 1, 127].pack('C*'))
      keyboard.send_bytes([0x90, 67, 100].pack('C*'))

      deadline = MB::U.clock_now + 3
      seen = nil
      until seen || MB::U.clock_now > deadline
        g = gate.sample(256).max
        n = number.sample(256).max
        m = mod.sample(256).max
        seen = [g, n, m] if g > 0
        sleep 0.005
      end

      expect(seen).to eq([1, 67, 1])
    ensure
      keyboard&.close
    end
  end
end

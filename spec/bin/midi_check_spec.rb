RSpec.describe('bin/midi_check.rb') do
  # A real process against a private JACK dummy server (JackDummy sets
  # JACK_DEFAULT_SERVER, which the script inherits).
  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }
  before(:each) { skip @jack_error if @jack_error }

  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE AUDIO_BACKEND].to_h { |k| [k, ENV.delete(k)] }
    ENV['AUDIO_BACKEND'] = 'null'
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  it 'reports the JACK server, the chosen API, ports, and a JACK loopback' do
    text = `bin/midi_check.rb --loopback 2>&1`
    expect($?).to be_success, text
    expect(text).to include(
      'RtMidi 6.0.0',
      'JACK server answers: yes',
      "Scripts' MIDI API: jack",
      'libjack loaded: ',
      'jack:',
      'Loopback (virtual output to an input connected to it):'
    )
    expect(text).to match(/^  jack: ok: 90 3c 64 in [\d.]+ ms via midi_check:loop\d+$/)
  end

  it 'prints MIDI arriving at a connected source with --listen' do
    keyboard = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_keys', nil, 'out')
    # Sends until the script exits, since its startup time varies
    sender = Thread.new do
      loop do
        keyboard.send_bytes([0x90, 64, 90].pack('C*'))
        sleep 0.25
      end
    end

    text = `bin/midi_check.rb --listen 2.5 -c mbspec_keys 2>&1`
    sender.kill
    expect($?).to be_success, text
    expect(text).to include('Listening for 2.5 s on jack (mbspec_keys:out)')
    expect(text).to match(/^\s+[\d.]+  90 40 5a$/)
  ensure
    sender&.join
    keyboard&.close
  end
end

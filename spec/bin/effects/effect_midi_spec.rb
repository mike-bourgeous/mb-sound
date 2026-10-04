require 'timeout'

# Effect scripts' MIDI controls (p.midi_cc): live MIDI on the shared JACK
# client, -m/--midi PORT, and -m/--midi FILE.mid.  Real processes.
RSpec.describe('effect scripts with MIDI control', :aggregate_failures) do
  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }
  before(:each) { skip @jack_error if @jack_error }

  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE OUTPUT_TYPE AUDIO_BACKEND].to_h { |k| [k, ENV.delete(k)] }
    ENV['OUTPUT_TYPE'] = 'null'
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # Runs the flanger, failing if it doesn't exit within +seconds+
  def flanger(*args, seconds: 30)
    text = nil
    pid = nil
    Timeout.timeout(seconds) do
      IO.popen(['bin/effects/flanger.rb', '--oversample', '1', *args], err: [:child, :out]) do |io|
        pid = io.pid
        text = io.read
      end
    end
    expect($?).to be_success, text
    text
  rescue Timeout::Error
    Process.kill('KILL', pid) rescue nil
    raise "flanger #{args.join(' ')} did not exit within #{seconds} s:\n#{text}"
  end

  it 'exits after a file plays out while live MIDI controls are open (user report)' do
    text = flanger('spec/test_data/arp_a7.flac')
    expect(text).to include('MIDI control enabled')
  end

  it 'connects its MIDI input to a port given with --midi' do
    keyboard = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_fx_keys', nil, 'out')
    text = flanger('spec/test_data/arp_a7.flac', '-m', 'mbspec_fx_keys')
    expect(text).to match(/MIDI control enabled\e\[0m \(mbspec_fx_keys:out\)/)
  ensure
    keyboard&.close
  end

  it 'follows a MIDI file given with --midi, also when rendering' do
    plain = tmp_path('plain.flac')
    midi = tmp_path('midi.flac')
    flanger('spec/test_data/arp_a7.flac', '-o', plain)
    text = flanger('spec/test_data/arp_a7.flac', '-o', midi, '-m', 'spec/test_data/mod_wheel.mid')
    expect(text).to include('MIDI control from spec/test_data/mod_wheel.mid')

    a = MB::Sound.read(plain)[0]
    b = MB::Sound.read(midi)[0]
    n = [a.length, b.length].min
    expect((a[0...n] - b[0...n]).abs.max).to be > 0.1
  end

  it 'refuses a --midi file that is not MIDI' do
    text = flanger('spec/test_data/arp_a7.flac', '-o', tmp_path('x.flac'), '-m', 'spec/test_data/arp_a7.flac')
    expect(text).to include('MIDI control disabled (spec/test_data/arp_a7.flac is not a MIDI file')
  end
end

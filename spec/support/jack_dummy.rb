# Starts a private JACK server with the dummy driver (no sound card), so
# MIDI specs can send real messages through JACK MIDI ports.  The server
# gets a unique name, and JACK_DEFAULT_SERVER points libjack (and RtMidi's
# JACK clients) at it.  --port-max 16 keeps its shared memory small (Docker's
# /dev/shm is 64 MB; JACK2's default needs about 100 MB).
#
# Usage in a spec file:
#     before(:context) { @jack_error = JackDummy.start }
#     after(:context) { JackDummy.stop }
#     before(:each) { skip @jack_error if @jack_error }
module JackDummy
  class << self
    # Starts the server and waits until a client can connect.  Returns nil
    # on success, or a reason to skip the specs.
    def start
      return 'jackd is not installed (apt install jackd2)' unless system('which jackd > /dev/null 2>&1')

      @name = "mbspec#{Process.pid}_#{rand(1 << 30)}"
      @old_server = ENV['JACK_DEFAULT_SERVER']
      ENV['JACK_DEFAULT_SERVER'] = @name
      @pid = spawn(
        'jackd', '--no-realtime', '--port-max', '16', '-n', @name, '-d', 'dummy', '-r', '48000', '-p', '256',
        out: File::NULL, err: File::NULL
      )

      # Wait for the server's socket before connecting: a JACK MIDI output
      # created while no server runs leaks RtMidi's ring buffers (see
      # spec/valgrind/ruby.supp)
      deadline = MB::U.clock_now + 5
      until MB::U.clock_now > deadline
        return nil if Dir.glob(["/dev/shm/jack_#{@name}_*", "/tmp/jack-#{Process.uid}/jack_#{@name}_*"]).any? && connectable?
        sleep 0.1
      end

      stop
      'the JACK dummy server did not start (another spec process may be using /dev/shm)'
    end

    # Stops the server and restores JACK_DEFAULT_SERVER.
    def stop
      if @pid
        Process.kill('TERM', @pid) rescue nil
        Process.wait(@pid) rescue nil
        @pid = nil
      end
      @old_server ? ENV['JACK_DEFAULT_SERVER'] = @old_server : ENV.delete('JACK_DEFAULT_SERVER')
    end

    private

    # RtMidi's JACK input only connects when a port opens, so open one
    def connectable?
      MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_probe', nil, 'probe').close
      true
    rescue MB::Sound::FastMIDI::Error
      false
    end
  end
end

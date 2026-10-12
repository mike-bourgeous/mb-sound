# Removing JACK ports while graphs change (2026-10-12): libjack's
# jack_port_unregister on an active client races the client's notification
# thread, which walks the client's port list in HandleLatencyCallback after
# any graph change on the server, and a spec process segfaulted there (JACK2
# issue #216).  The shared client (mb_jack.c) keeps released ports as
# disconnected spares and unregisters them only while deactivated, and
# fast_midi deactivates RtMidi's JACK clients before their ports go.
#
# The stress example runs JACK_STRESS_SECONDS (default 0.5) in the suite; for
# a long local run:
#     JACK_STRESS_SECONDS=120 bundle exec rspec --tag jack_stress
# Before the fix, a C version of the same pattern (one port unregistered and
# registered again every 0-3 ms while another client connects and
# disconnects it) crashed libjack about once a minute; the Ruby version is
# slower per cycle, so a crash took longer to come.
RSpec.describe('JACK port teardown', :aggregate_failures) do
  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }
  before(:each) { skip @jack_error if @jack_error }

  let(:fa) { MB::Sound::FastAudio }
  let(:client) { "mbspec_teardown#{rand(1 << 20)}" }

  before(:each) { @opened = [] }
  after(:each) do
    @opened.each(&:close)
    fa.jack_close
  end

  def midi_in(name)
    fa::JackMIDIInput.new(client, name, 4096).tap { |m| @opened << m }
  end

  def midi_out(name)
    fa::JackMIDIOutput.new(client, name, 4096).tap { |m| @opened << m }
  end

  def ports
    fa.jack_ports("^#{client}:", nil, 0).map { |n| n.delete_prefix("#{client}:") }.sort
  end

  it 'keeps closed ports as disconnected spares while others are open, reuses them, and removes them when idle' do
    keep = midi_out('keep')
    a = midi_in('a')
    b = midi_in('b')
    fa.jack_connect(keep.port_name, a.port_name)
    fa.jack_connect(keep.port_name, b.port_name)

    a.close
    b.close
    expect(ports.length).to eq(3)
    expect(ports).to include('keep')
    spares = ports.grep(/\Aspare_midi_in_\d+\z/)
    expect(spares.length).to eq(2)
    expect(fa.jack_connections(keep.port_name)).to eq([])

    # Reused under the new name, so spares don't pile up
    c = midi_in('c')
    expect(c.port_name).to eq("#{client}:c")
    expect(ports.grep(/\Aspare_/).length).to eq(1)
    20.times { midi_in('d').close }
    expect(ports.grep(/\Aspare_/).length).to eq(1)

    # An output port can't take an input spare
    o = midi_out('o')
    expect(o.port_name).to eq("#{client}:o")
    expect(ports.grep(/\Aspare_midi_in_/).length).to eq(1)

    [keep, c, o].each(&:close)
    expect(ports).to eq([])
    expect(fa.jack_info).not_to be_nil

    # The client still works after the deactivation that removed the spares
    out = midi_out('again_out')
    inp = midi_in('again_in')
    fa.jack_connect(out.port_name, inp.port_name)
    out.write([0x90, 60, 100].pack('C*'))
    expect(inp.read(true).map(&:last)).to eq([[0x90, 60, 100].pack('C*')])
  end

  it 'survives closing ports while another client changes the graph', :jack_stress do
    seconds = Float(ENV['JACK_STRESS_SECONDS'] || 0.5)
    keyboard = MB::Sound::FastMIDI::Output.new(:jack, "#{client}_kbd", nil, 'out')
    target = midi_in('x')
    cycles = 0
    deadline = MB::U.clock_now + seconds

    # Graph changes make the server send latency notifications to every
    # client, which is when an unregister used to crash
    churn = Thread.new do
      while MB::U.clock_now < deadline
        fa.jack_connect("#{client}_kbd:out", "#{client}:x")
        fa.jack_disconnect("#{client}_kbd:out", "#{client}:x")
        sleep 0.0002
      end
    end

    while MB::U.clock_now < deadline
      sleep rand * 0.003
      target.close
      target = midi_in('x')

      # An outside RtMidi JACK client closed right after a graph change
      other = MB::Sound::FastMIDI::Output.new(:jack, "#{client}_other", nil, 'out')
      fa.jack_connect("#{client}_other:out", "#{client}:x")
      other.close
      cycles += 1
    end
    churn.join

    expect(cycles).to be > 0
    expect(ports.grep(/\Aspare_/).length).to be <= 1
  ensure
    churn&.kill
    keyboard&.close
  end
end

require_relative '../../../../support/ui_helpers'

# The MIDI device browser pane (midi-out-1): destinations and sources from
# MIDI::Ports, the tracks playing to them, and its mode keys.
RSpec.describe(MB::Sound::UI::Panes::MidiPorts, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pane) { ui.panes.fetch(:midi_ports) }

  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE JACK_CLIENT_NAME].to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  def draw(state, w = 70, h = 8)
    grid = MB::Term::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), ui_fake_snapshot, state.merge!(title_in_rule: true))
    grid.to_text(:none).lines.map(&:rstrip)
  end

  it 'is found by its aliases' do
    expect(ui.pane_name(:midi_devices)).to eq(:midi_ports)
    expect(ui.pane_name(:ports)).to eq(:midi_ports)
  end

  it 'guesses track names from port names' do
    port = ->(name) { c, p = name.split(':', 2); MB::Sound::MIDI::Ports::Port.new(api: :jack, name: name, client: c, port: p, direction: :out, connections: [], physical: false, own: false, index: nil) }
    expect(described_class.track_name(port['Midi-Bridge:KRONOS 1:(playback_0) KRONOS MIDI 1'])).to eq(:kronos)
    expect(described_class.track_name(port['system:midi_playback_1'])).to eq(:synth)
    expect(described_class.track_name(port['Surge XT:MIDI In'])).to eq(:surge)
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) do
      skip @jack_error if @jack_error
      ENV['MIDI_API'] = 'jack'
      ENV['JACK_CLIENT_NAME'] = 'mbspec_pp'
      @synth = MB::Sound::FastMIDI::Input.new(:jack, 'mbspec_kronos', nil, 'in', 100)
      @keys = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_keys', nil, 'out')
    end
    after(:each) do
      @synth&.close
      @keys&.close
      MB::Sound::MIDI::Destination.close
      MB::Sound::Jack.close
    end

    it 'lists destinations then sources, picks with the arrows, and puts a track line on the console with Enter' do
      state = {}
      text = draw(state).join("\n")
      expect(text).to include('→ mbspec_kronos:in', '← mbspec_keys:out')
      expect(text.index('mbspec_kronos:in')).to be < text.index('mbspec_keys:out')

      state[:mode] = true
      ports = state[:ports]
      i = ports.index { |p| p.name == 'mbspec_kronos:in' }
      i.times { pane.key_pick_port(state, 1) }
      msg = pane.key_action(:pick_port, state, 0)
      expect(msg).to include('destination mbspec_kronos:in')
      r = pane.key_action(:track_line, state)
      expect(r).to be_a(MB::Sound::UI::PaneKeys::Paste)
      expect(r.code).to eq('track :mbspec_kronos, midi_out("mbspec_kronos:in")')
      expect(pane.key_action(:edit_line, state).code).to eq(r.code)

      x = pane.key_action(:port_panic, state)
      expect(x.code).to eq('midi_out("mbspec_kronos:in").panic(:all)')

      expect(pane.key_action(:test_note, state)).to eq('test note (C4) on mbspec_kronos:in')
      got = []
      deadline = MB::U.clock_now + 2
      while got.length < 2 && MB::U.clock_now < deadline
        got.concat(@synth.read.map { |_, b| b.bytes })
        sleep 0.01
      end
      expect(got).to eq([[0x90, 60, 100], [0x80, 60, 0]])

      # a source has no track line
      j = state[:ports].index { |p| p.name == 'mbspec_keys:out' }
      state[:pick] = [:jack, 'mbspec_keys:out', :in]
      expect(j).not_to be_nil
      expect(pane.key_action(:track_line, state)).to match(/is a source/)
    end

    it 'shows the tracks playing to a port' do
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), realtime: false, channels: 1)
      allow(MB::Sound::Session).to receive(:existing).and_return(s)
      s.arrangement.track(:kronos, MB::Sound.midi_out('mbspec_kronos'))
      text = draw({}).join("\n")
      expect(text).to match(/mbspec_kronos:in.*:kronos/)
      expect(MB::Sound.midi_ports(:out).to_s).to match(/out  mbspec_kronos:in.*tracks: :kronos/)
    ensure
      s&.close
    end
  end
end

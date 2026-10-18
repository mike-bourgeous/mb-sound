require_relative '../../../../support/ui_helpers'

# The set's panes (ux-1 r3 items 29 and 32): buses and sends with the
# routing tree, landed changes, the launch lane, clips, MIDI; what Poll
# gathers for them from a Session; meters and scopes delayed to what is
# heard.
RSpec.describe('UI session panes', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  def snap_with(**slow)
    base = ui_fake_snapshot
    base.with(slow: base.slow.with(**slow))
  end

  def draw(name, snap, w = 50, h = 12)
    grid = MB::Sound::Plot::Text::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, { title_in_rule: true })
    grid.to_text(:none).lines.map(&:rstrip)
  end

  it 'draws buses with their sends as meters and the routing tree from the master' do
    snap = snap_with(
      buses: [ui::BusInfo.new(name: :verb, to: :master, description: 'reverb', asleep: false, muted: false),
              ui::BusInfo.new(name: :drums, to: :master, description: 'bypass', asleep: true, muted: false)].freeze,
      routes: { bass: { to: :master, send: { verb: 0.25 } }, kick: { to: :drums, send: {} } }.freeze
    )
    lines = draw(:buses, snap.with(bus_levels: nil, send_levels: nil))
    text = lines.join("\n")
    expect(lines[0]).to start_with('● verb').and include('→ master', 'reverb')
    expect(text).to include('drums', 'asleep')
    expect(lines[1]).to match(/\A ← bass\s+-12\.0 dB\z/) # (0.25 = -12 dB; no level meter until the feed sends levels)
    expect(lines[3]).to match(/\A ← kick\s+to:\z/) # (routed whole)
    expect(text).to include('routing', 'master', '├─ verb', 'bass (send)', 'kick')
    expect(draw(:buses, snap_with(buses: [].freeze)).first).to start_with('no buses')
  end

  it 'logs landed changes newest at the bottom' do
    landed = [ui::LandedInfo.new(seq: 1, kind: :add, subject: :bass, lands: '9:1', pos: 8r, at: nil),
              ui::LandedInfo.new(seq: 2, kind: :mute, subject: :pad, lands: '17:1', pos: 16r, at: nil)].freeze
    lines = draw(:log, snap_with(landed: landed), 30, 4)
    expect(lines[0, 2]).to eq(['9:1    add :bass', '17:1   mute :pad'])
  end

  it 'shows queued changes in the launch lane, counting down to the next, and flashes one that landed' do
    lines = draw(:lane, ui_fake_snapshot, 41, 4)
    # pos 16.5 (17:3): the knob change at 16.5 is due now, the mute at 17 two beats on
    expect(lines[0]).to eq('next knob :cut in 0.0 beats')
    expect(lines[1]).to start_with('▶◆')
    expect(lines[1]).to include('◆')
    flash = [ui::LandedInfo.new(seq: 3, kind: :scene, subject: :drop, lands: '17:1', pos: 16r, at: MB::U.clock_now)].freeze
    expect(draw(:lane, snap_with(landed: flash), 41, 4)[0]).to include('landed: scene :drop')
  end

  it 'shows mapped controllers beside their knobs and the latest MIDI events' do
    midi = ui::MidiInfo.new(events: [['17:1', :keys, :on, 'C4 v100'], ['17:2', :keys, :cc, 'cc 21 = 64']].freeze, ccs: { 21 => 64 }.freeze, mapped: [[:cut, 21]].freeze)
    lines = draw(:midi, snap_with(midi: midi), 50, 5)
    expect(lines[0]).to start_with('cut    cc21')
    expect(lines.join("\n")).to include('C4 v100', 'cc 21 = 64')
  end

  it 'gathers buses, routes, landed changes, clips, and MIDI from a Session (Poll)' do
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session) do
      session.bus(:verb) { |sig| sig * 0.5 }
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop.named(:riff)
      session.arrangement.track(:bass, q: 1) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }
      session.route(:bass, send: { verb: 0.5 })
      session.arrangement.play(:bass, clip)
      4.times { session.process_buffer }
      poll = ui::Poll.new(session)
      slow, = poll.call
      expect(slow.buses.map(&:name)).to eq([:verb])
      expect(slow.routes[:bass][:send][:verb]).to be_within(1e-9).of(0.5)
      expect(slow.clips.map(&:name)).to include('riff')
      riff = slow.clips.find { |c| c.name == 'riff' }
      expect(riff.pattern).to start_with('█')
      expect(riff.used).to include(:bass)
      expect(slow.landed.map(&:subject)).to include(:bass)
      expect(slow.midi).to be_a(ui::MidiInfo)
      poll.close
    end
  ensure
    session&.close
    MB::Sound.rewind
  end

  it 'draws meters and scopes from the snapshot being heard, not the newest' do
    band, = ui_fake_band(:band)
    now = MB::U.clock_now
    old = ui_fake_snapshot(t: now - 0.03, seq: 1).with(latency: 0.02)
    newer = ui_fake_snapshot(t: now - 0.005, seq: 2).with(latency: 0.02)
    expect(band.send(:heard, old, now)).to equal(old)
    expect(band.send(:heard, newer, now)).to equal(old) # (heard 15 ms from now)
    expect(band.send(:heard, ui_fake_snapshot(seq: 3), now).seq).to eq(3) # (no latency: the newest)
  end
end

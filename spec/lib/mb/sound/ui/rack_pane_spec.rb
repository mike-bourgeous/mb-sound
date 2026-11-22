require_relative '../../../../support/ui_helpers'

# The rack pane (racks phase V, design/notes/drawing.md): one instance's
# header, ports, knobs, slots, and its inner graph (RackInfo#graph) drawn
# by rank in the rest of the pane; view-only keys pan the drawing and
# change the instance.
RSpec.describe('UI rack pane', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pane) { ui.panes.fetch(:rack) }

  after { ui::Panes::Racks.selected = nil }

  # A rack's drawing (Plot::Graph) and RackInfos carrying it, as Poll
  # gives them.
  let(:graph) {
    MB::Sound.arack(side: :audio) { |sig, side:| sig.duck(side).filter(:lowpass, cutoff: 1200).delay(0.1) }.graph
  }
  let(:racks) {
    base = ui_fake_racks.first
    [base.with(graph: graph), base.with(name: :wide, path: :"pad/wide", knobs: [].freeze, graph: nil)].freeze
  }
  let(:snap) {
    s = ui_fake_snapshot(rack_knobs: true)
    s.with(slow: s.slow.with(racks: racks))
  }

  def draw(snap, state = { title_in_rule: true }, w: 90, h: 24)
    grid = MB::Term::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  def key(state, action, *args) = pane.key_action(action, state, *args)

  it 'draws the header, typed ports, knobs with values, slots, then the drawing' do
    lines = draw(snap)
    expect(lines[0]).to eq('bass/dub  effect  audio(sig) + audio(side) -> audio  lat 72 smp  1 of 2')
    expect(lines[1]).to eq('in sig:audio side:audio?  out audio')
    expect(lines[2]).to eq('knobs  space 0.6 (0..1)  tone 1800 Hz (600..8000 exp)')
    expect(lines[3]).to eq('slots none (slots come with live swaps, racks R3)')
    expect(lines[4..].first(graph.height)).to eq(graph.lines(color: :none).map { |l| l[0, 90].rstrip })
    expect(lines.join("\n")).to include('┌ sig ┐', '┌ side ┐', 'duck', 'filter', '┌ out ┐')
  end

  it 'says when there are no racks or no drawing' do
    s = ui_fake_snapshot.with(slow: ui_fake_slow.with(racks: [].freeze))
    expect(draw(s)[0]).to start_with('no racks')
    st = { title_in_rule: true, path: :"pad/wide" }
    expect(draw(snap, st)[3]).to start_with("(no drawing: wide didn't build on stand-ins)")
  end

  it 'pans the drawing with view-only keys, clamped to it, and goes home' do
    st = { title_in_rule: true, mode: true }
    full = graph.lines(color: :none)
    draw(snap, st, w: 30, h: 12)
    expect(key(st, :pan, 1, 0)).to be_nil
    expect(key(st, :pan, 0, 1)).to be_nil
    lines = draw(snap, st, w: 30, h: 12)
    expect(st[:scroll]).to eq([4, 2])
    expect(lines[4]).to eq(full[2][4, 30].to_s.rstrip)
    expect(lines[11]).to end_with('…')
    30.times { key(st, :pan, 1, 1, :quarter) }
    draw(snap, st, w: 30, h: 12)
    expect(st[:scroll]).to eq([graph.width - 30, graph.height - 8])
    key(st, :home)
    draw(snap, st, w: 30, h: 12)
    expect(st[:scroll]).to eq([0, 0])
    expect(pane.class.mode_keymap).not_to be_nil
  end

  it 'shows the instance the racks pane picked, and n/p step through instances with a flash' do
    st = { title_in_rule: true, mode: true }
    ui::Panes::Racks.selected = :"pad/wide"
    expect(draw(snap, st)[0]).to start_with('pad/wide')
    ui::Panes::Racks.selected = nil
    expect(draw(snap, st)[0]).to start_with('bass/dub')
    expect(key(st, :instance, 1)).to eq('rack pad/wide (2 of 2)')
    expect(draw(snap, st)[0]).to start_with('pad/wide')
    expect(key(st, :instance, 1)).to eq('rack bass/dub (1 of 2)')
    expect(key({}, :instance, 1)).to eq('no rack instances')
  end

  it "follows the racks pane's picked knob" do
    rk = { title_in_rule: true, mode: true }
    # (the knobless instance first: the pick lands on the second)
    s = snap.with(slow: snap.slow.with(racks: racks.reverse.freeze))
    grid = MB::Term::Cells.new(60, 8)
    ui.panes.fetch(:racks).draw(ui::Canvas.new(grid, 0, 0, 60, 8), s, rk)
    expect(ui::Panes::Racks.selected).to eq(:"bass/dub")
    expect(draw(s)[0]).to start_with('bass/dub')
    expect(draw(s)[0]).to end_with('2 of 2')
  end

  it 'is a set pane, off the wall, with its keys in the help' do
    expect(ui::SESSION_PANES).to include(:rack)
    expect(pane.description).to include('inner graph')
    expect(ui::PaneKeys.kind_of(pane)).to eq(:rackdetail)
  end

  describe 'with a real Session' do
    before do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    end

    after do
      @poll&.close
      @session&.close
      MB::Sound.rewind
    end

    it "draws a playing rack's inside from Poll's RackInfo" do
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.instance_eval do
          arack(:dub) { |sig| (sig * knob(:space, 0.35)).filter(:lowpass, cutoff: 1800) }
          bg :drone, 110.hz.saw.at(-30.db).then(&rack(:dub))
        end
      end
      @poll = ui::Poll.new(@session)
      4.times { @session.process_buffer }
      slow, = @poll.call
      info = slow.racks.find { |r| r.name == :dub }
      expect(info.graph).to be_a(MB::Sound::Plot::Graph)
      expect(Ractor.shareable?(info)).to eq(true)
      s = ui_fake_snapshot.with(slow: slow, knobs: [].freeze)
      text = draw(s).join("\n")
      expect(text).to include('dub  effect', 'knobs  space 0.35 (0..1)', '┌ sig ┐', 'knob dub/space', 'filter', 'cutoff 1800 Hz', '┌ out ┐')
    end
  end
end

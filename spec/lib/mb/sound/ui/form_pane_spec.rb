require_relative '../../../../support/ui_helpers'

# The form pane's own mode (ui-phase1-1, the 2026-11-21 plan's Phase 1
# item 3): pick a section, go there, loop it, move on, skip, finish, and
# the transport, each a console line a player would type.
RSpec.describe('UI form pane keys', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pane) { ui.panes.fetch(:form) }
  let(:rows) { [[:intro, '4 bars'], [:verse, '8 bars x2'], [:drop, '8 bars'], [:break, '4 bars'], [:outro, '4 bars']].map(&:freeze).freeze }

  def snap_with(looping: false, ended: false, sections: rows)
    base = ui_fake_snapshot
    form = base.slow.form.with(looping: looping, ended: ended, sections: sections)
    base.with(slow: base.slow.with(form: form))
  end

  def paint(snap, state, w: 50, h: 1)
    grid = MB::Term::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state.merge!(title_in_rule: true))
    grid.to_text(:none).lines.map(&:rstrip)
  end

  it 'draws as before outside its mode, and the picked section (one row) or the sections (more rows) in it' do
    snap = snap_with
    plain = paint(snap, {})
    expect(plain[0]).to start_with('drop 1 ').and include('break 21:1')
    expect(paint(snap, {}, h: 4)[0]).to eq(plain[0])
    st = { mode: true }
    expect(paint(snap, st)[0]).to match(/\A3\/5 ▶ drop 8 bars\z/) # (the one playing, picked at first)
    lines = paint(snap, st, h: 6)
    expect(lines[0]).to eq(plain[0]) # (the status line on top)
    expect(lines[1..]).to eq(['  intro 4 bars', '  verse 8 bars x2', '▶ drop 8 bars', '→ break 4 bars  at 21:1', '  outro 4 bars'])
    # (scrolls to the picked one)
    st[:pick] = :outro
    expect(paint(snap, st, h: 3)[1..]).to eq(['→ break 4 bars  at 21:1', '  outro 4 bars'])
  end

  it 'picks a section and runs goto, loop!, practice, onward, skip, finish; Space is the transport' do
    run = ui::PaneKeys::Run
    st = { mode: true }
    paint(snap_with, st)
    expect(pane.key_action(:goto, st)).to eq(run['goto :drop', "drop next (at this section's end)"])
    expect(pane.key_action(:pick, st, -1)).to eq('verse 8 bars x2 (Enter goes there next, r loops it)')
    expect(pane.key_action(:goto, st).code).to eq('goto :verse')
    expect(pane.key_action(:loop, st)).to eq(run['practice :verse', 'verse next, looping (n moves on)'])
    3.times { pane.key_action(:pick, st, -1) }
    expect(st[:pick]).to eq(:intro) # (stops at the top)
    pane.key_action(:scroll, st, 0) # (the arrows' default action picks too)
    pane.key_action(:pick, st, 1)
    expect(pane.key_action(:loop, st)).to eq(run['loop!', 'drop loops (n or r moves on)']) # (the one playing)
    paint(snap_with(looping: true), st)
    expect(pane.key_action(:loop, st).code).to eq('onward') # (r again: its inverse)
    expect(pane.key_action(:onward, st).code).to eq('onward')
    expect(pane.key_action(:skip, st).code).to eq('skip')
    expect(pane.key_action(:finish, st).code).to eq('finish')
    expect(pane.key_action(:transport, st)).to eq(MB::Term::Input::Action.of(:pause))

    km = ui::Panes::Form.mode_keymap.entries
    { [:enter, []] => :goto, ['r', []] => :loop, ['n', []] => :onward, ['>', []] => :skip, ['f', []] => :finish, [' ', []] => :transport }.each do |chord, action|
      expect(km.find { |b| b.chord == chord }&.action).to eq(action), chord.inspect
    end
  end

  it 'says why, never raises, without a form or after it ended' do
    st = { mode: true }
    paint(snap_with(sections: [].freeze), st, h: 2)
    %i[goto loop onward skip finish].each { |a| expect(pane.key_action(a, st)).to start_with('no form playing') }
    expect(pane.key_action(:pick, st, 1)).to start_with('no form playing')
    lines = paint(snap_with(ended: true), st, h: 2)
    expect(lines).to eq(['form ended  scene drop', 'no form to steer (flow do ... end, or a demo)'])
    expect(pane.key_action(:goto, st)).to eq('the form ended (start plays it again)')
    expect(pane.key_action(:goto, {})).to start_with('no form playing') # (before the first frame)
  end

  it 'lists a form\'s sections in the order they first play, with lengths and passes (Form::Playback#section_rows)' do
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    form = MB::Sound::Form.build { intro 4, scene: false; verse 8.bars, times: 2, scene: false; chorus 8, scene: false; verse 4; outro 1, scene: false }
    pb = MB::Sound::Form::Playback.new(session.arrangement, form, seed: 1)
    expect(pb.section_rows).to eq([[:intro, '4 bars'], [:verse, '8 bars x2 · 4 bars x2'], [:chorus, '8 bars'], [:outro, '1 bar']])
    expect(pb.section_rows).to be_frozen
    expect(pb.section_rows).to equal(pb.section_rows)
  ensure
    session&.close
  end

  describe 'on a screen' do
    after do
      @tiles&.stop
      @term&.close
      @session&.close
      MB::Sound.rewind
    end

    it 'steers the demo\'s flow from its keys: Enter goes to the picked section, r loops, Space pauses' do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      expect {
        MB::Sound::Session.with_context(session: @session) { MB::Sound.demo(:night_bus); MB::Sound.start }
      }.to output(/night_bus/).to_stdout
      8.times { @session.process_buffer }
      pb = @session.arrangement.playback
      expect(pb&.section).not_to be_nil
      @tiles, @term = ui_tiles(:session, rows: 60, cols: 236, session: @session)
      @tiles.show(:form, at: :repl) unless @tiles.tiler.layout.panes.include?(:form)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.004; end }
      @tiles.enter(:form)
      st = @tiles.instance_variable_get(:@states)[:form]
      expect(wait_until { st[:snap]&.form&.sections&.any? && @tiles.router.mode == :pane }).to eq(true)
      target = pb.section_rows.map(&:first).find { |n| n != pb.section }
      steps = pb.section_rows.index { |r| r[0] == target } - pb.section_rows.index { |r| r[0] == pb.section }
      steps.abs.times { @term.write(steps > 0 ? "\e[B" : "\e[A") }
      expect(wait_until { st[:pick] == target }).to eq(true), st[:pick].inspect
      @term.write("\r")
      expect(wait_until { pb.upcoming.section == target }).to eq(true), pb.upcoming.inspect
      @term.type('r') # (the picked one is not playing: practice)
      expect(wait_until { pb.looping? }).to eq(true)
      # (each key ran its console line, shown in the REPL pane)
      expect(@term.wait_for("goto #{target.inspect}")).to eq(true)
      expect(@term.wait_for("practice #{target.inspect}")).to eq(true)
      @term.write(' ') # (Space: the transport, as NAV Space)
      expect(@term.wait_for(/paused/)).to eq(true), @term.lines.last
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
    end
  end
end

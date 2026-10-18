require_relative '../../../../support/ui_helpers'

# Text that doesn't fit is never chopped silently (ux-1 r3 item 38): every
# text pane fed over-long names ends cut lines with an ellipsis, and the
# messages panes wrap long messages so their tails stay readable.
RSpec.describe('UI text fitting', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  def long = 'LONGNAME_' * 8

  def long_snapshot
    base = ui_fake_snapshot
    slow = base.slow.with(
      tracks: [ui::TrackInfo.new(name: :"#{long}track", q: '1', clip: "#{long}clip", armed: false)].freeze,
      queued: [ui::QueuedInfo.new(seq: 1, kind: :knob, subject: :"#{long}subject", lands: '18:1', pos: 17r)].freeze,
      buses: [ui::BusInfo.new(name: :"#{long}bus", to: :master, description: "#{long}chain", asleep: false, muted: false)].freeze,
      routes: { "#{long}player": { to: :master, send: { "#{long}bus": 0.5 } } }.freeze,
      landed: [ui::LandedInfo.new(seq: 2, kind: :mute, subject: :"#{long}landed", lands: '17:1', pos: 16r, at: nil)].freeze,
      clips: [ui::ClipInfo.new(name: "#{long}clip", kind: :clip, bars: 1r, pattern: '█' * 32, used: [:"#{long}track"].freeze)].freeze,
      midi: ui::MidiInfo.new(events: [['17:1', :"#{long}src", :on, "#{long}event"]].freeze, ccs: {}.freeze, mapped: [].freeze),
      recording: [].freeze,
      matrix: ui_fake_matrix(long),
      racks: ui_fake_racks(long),
      form: base.slow.form.with(section: :"#{long}section", next: :"#{long}next")
    )
    base.with(
      slow: slow,
      parts: [ui::PartLoad.new(name: :"#{long}part", kind: :player, state: :playing, load: 0.1)].freeze,
      knobs: [ui::KnobValue.new(name: :"#{long}knob", value: 1.0, spec: ui_knob_spec(:"#{long}knob", 0.0, 0.0..2.0, unit: "#{long}unit"))].freeze
    )
  end

  # The pane's rows drawn into a +w+ x +h+ canvas.
  def draw(pane, snap, w, h)
    grid = MB::Sound::Plot::Text::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, { title_in_rule: true })
    grid.to_text(:none).lines.map(&:chomp)
  end

  it 'ends every cut line of every text pane in an ellipsis' do
    snap = long_snapshot
    ui.panes.each_value do |pane|
      next if pane.bytes? || %i[messages message keyboard].include?(pane.name)
      rows = draw(pane, snap, 30, 6)
      cut = rows.select { |r| r.include?('LONGNAM') }
      expect(cut).not_to be_empty, "#{pane.name} shows no long name: #{rows.inspect}" unless %i[transport meters].include?(pane.name)
      cut.each { |r| expect(r).to include('…'), "#{pane.name}: #{r.inspect}" }
      # Whatever reaches the right edge was cut with an ellipsis, or is a number or meter that fits
      rows.each { |r| expect(r[-1]).to match(/[\s…\d%█▏▎▍▌▋▊▉·│]/), "#{pane.name}: #{r.inspect}" }
    end
  end

  it 'clips at the canvas, marking anything but blanks' do
    expect(ui::Canvas.clip('abcdef', 4)).to eq('abc…')
    expect(ui::Canvas.clip('ab    ', 3)).to eq('ab ')
    expect(ui::Canvas.clip('abc', 3)).to eq('abc')
  end

  it 'wraps with a hanging indent, breaking words longer than a line' do
    lines = ui::Canvas.wrap('one two three /a/very/long/path/name.rb:12 end', 14, indent: 2)
    expect(lines).to eq(['one two three', '  /a/very/lon\\', '  g/path/name\\', '  .rb:12 end'])
    expect(lines.map(&:length).max).to be <= 14
    expect(ui::Canvas.wrap("first line\nsecond", 20)).to eq(['first line', 'second'])
  end

  it 'wraps messages beside their numbers, newest at the bottom, keeping a long warning\'s tail' do
    ui.messages.clear
    ui.messages.add('older warning', now: 1.0)
    ui.messages.add("Track :y can't monitor live MIDI (ArgumentError: wrong number of arguments (given 1, expected 0)) TAILEND", severity: :error, now: 2.0)
    rows = draw(ui.panes[:messages], nil, 30, 6)
    text = rows.join("\n")
    expect(text).to include('TAILEND')
    expect(rows.last).to include('TAILEND') # (the newest at the bottom)
    expect(rows.find { |r| r.include?('older') }).to start_with('2 ')
    expect(rows.find { |r| r.include?('Track :y') }).to start_with('1 ')
    expect(rows.select { |r| r.start_with?('  ') && !r.strip.empty? }).not_to be_empty # (hanging indent)

    detail = ui.panes[:message]
    detail.index = 1
    rows = draw(detail, nil, 30, 8).join("\n")
    expect(rows).to include('#1 error', 'TAILEND')
  ensure
    ui.messages.clear
  end
end

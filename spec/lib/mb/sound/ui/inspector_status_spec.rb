require_relative '../../../../support/ui_helpers'

# The status line over a focused inspector (sd-ux-fixes-1): what the
# review's tasks read there.
RSpec.describe('the inspector\'s status line', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    ui::Inspect.target = nil
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
  end

  after do
    ui::Inspect.target = nil
    @tiles&.stop
    @term&.close
    @session&.close
    MB::Sound.rewind
  end

  # A :sound screen over track :bass playing +instrument+, the inspector in
  # its mode; the snapshot follows the session's knobs.
  def screen(instrument = :dnb_reese)
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:bass, instrument)
      MB::Sound.bg(:bass, MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop)
    end
    4.times { @session.process_buffer }
    ui::Inspect.target = { track: :bass, node: nil }
    poll = ui::Poll.new(@session)
    snap = -> {
      slow, = poll.call([:inspect])
      ui_fake_snapshot.with(slow: slow, knobs: @session.knobs.map { |n, k| ui::KnobValue.new(name: n, value: k.value, spec: k.spec) }.freeze)
    }
    @now = 1.0
    @term = UIHelpers::FakeTerminal.new(40, 140)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:sound), input: @term.slave, output: @term.slave, repl: :none, session: @session,
                           probe: false, size: [40, 140], clock: -> { @now }, source: snap,
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @tiles.start(thread: false)
    @tiles.enter(:inspector)
    @tiles.refresh
  end

  def status = @tiles.to_text.lines.last.to_s

  def act(*a)
    @tiles.send(:pane_action, :inspector, *a)
    @now += 0.05
    @tiles.refresh
  end

  # The review's #10: after a section jump the jump's flash stayed about
  # 3.5 s (9 Down presses) over Enter's hint
  it 'shows Enter\'s hint at once when a key changes the pick after a jump\'s flash' do
    screen
    act(:section, :amp)
    expect(status).to match(/AMP /)
    act(:pick, 1)
    expect(status).to include('Enter: ')
    expect(status).not_to match(/AMP \w/)
  end

  # The review's #16: after the first time (the warning is once per knob), a
  # typed value past the range was limited silently
  it 'says "limited to" on the turn line and the status line every time a typed value is limited' do
    screen
    live = MB::Sound.live?
    MB::Sound.live = true
    turn = ui::PaneKeys::Turn['turn :"bass/cutoff", 99999', 'cutoff 99999']
    2.times do
      @tiles.send(:pane_result, :inspector, turn)
      @now += 0.05
      @tiles.refresh
      expect(status).to match(/cutoff 99999: limited to \d+ \(bass\/cutoff goes \d+\.\.\d+\)/)
      expect(@tiles.instance_variable_get(:@states)[:inspector][:turn_line]).to match(/limited to \d+/)
    end
    4.times { @session.process_buffer }
    expect(@session.knobs[:"bass/cutoff"].value).to eq(@session.knobs[:"bass/cutoff"].spec.range.end)
  ensure
    MB::Sound.live = live
  end

  # The review's #22: noise rows offered frequency and phase (dead ends),
  # and an oscillator's start phase was the first SOURCE stop
  it 'hides noise\'s frequency and phase, and starts a row past its start phase' do
    screen(:init)
    act(:section, :source)
    st = @tiles.instance_variable_get(:@states)[:inspector]
    expect(st[:at]).not_to be_nil
    expect(st[:at][1]).not_to eq(:phase)
    info = st[:snap].inspector
    osc = info.nodes[st[:at][2]]
    expect(osc.section).to eq(:source)
    expect(ui.panes.fetch(:inspector).shown_params(osc).map(&:first).last).to eq(:phase)

    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.track(:n) { |c| c.synth { |v| (v.hz.saw + MB::Sound.noise.at(0.1)) * v.amp_env } }
      MB::Sound.bg(:n, MB::Sound.seq(MB::Sound::C3).n4.loop)
    end
    4.times { session.process_buffer }
    g = ui::Inspect::Gatherer.new
    info = g.call(session, { track: :n, node: nil })
    noise = info.nodes.index { |n| n.label == 'noise' }
    expect(g.call(session, { track: :n, node: noise }).nodes[noise].params.values.keys).not_to include(:frequency, :phase)
  ensure
    session&.close
  end

  # The review's #24: the header left out the instrument for acid (a
  # library instrument written in Ruby, not a graph document)
  it 'names the library instrument in the header' do
    screen(:acid)
    expect(@tiles.to_text).to match(/bass  acid  1\/1/)
  end

  # The review's #26: the P panel of a hand-written patch showed one cell
  # and none of its envelope's literals; F worked only on presets
  it 'shows a hand-written patch\'s envelope literals as panel cells, and F says why it does nothing there' do
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:hand) { |c| c.synth { |v| v.hz.saw.lp4(900) * v.amp_env(0.01, 0.2, 0.6, 0.4) } }
    end
    screen(:acid)
    MB::Sound::Session.with_context(session: @session) { MB::Sound.bg(:hand, MB::Sound.seq(MB::Sound::C3).n4.loop, on: :now) }
    4.times { @session.process_buffer }
    pane = ui.panes.fetch(:inspector)
    st = @tiles.instance_variable_get(:@states)[:inspector]
    3.times do
      break if st[:snap]&.inspector&.track == :hand
      act(:track, 1)
      @now += 0.5
      @tiles.refresh
    end
    act(:view)
    info = st[:snap].inspector
    expect(info.track).to eq(:hand)
    cells = pane.send(:pick_list, st, info).select { |e| e[0] == :param }.map { |e| e[1] }
    expect(cells).to include(:attack, :decay, :sustain, :release)
    expect(pane.key_action(:fixed, st)).to match(/hand plays a patch block: its literals are cells already/)
    act(:track, 1)
    @now += 0.5
    @tiles.refresh
    expect(pane.key_action(:fixed, st)).to match(/bass plays acid, library code rather than a graph document/)
  end

  # The review's minor items: a row's tail said "reso" where its knob row
  # said "resonance"; the plumbing count read as noise
  it 'names a knob-driven param in a row\'s tail as its knob row does, and hides the plumbing count' do
    screen
    pane = ui.panes.fetch(:inspector)
    st = @tiles.instance_variable_get(:@states)[:inspector]
    info = st[:snap].inspector
    lp4 = info.nodes.find { |n| n.knob_of(:resonance) }
    expect(lp4).not_to be_nil
    knobs = st[:snap].knobs.to_h { |k| [k.name, k] }
    tail = pane.send(:row_tail, lp4, knobs)
    expect(tail).to include('resonance ')
    expect(tail).not_to include('reso ')
    expect(@tiles.to_text).not_to match(/\d+ plumbing nodes/)
  end

  # The review's #14 (breath_vowel, on the held library-voices-1 branch,
  # built the same way): a knob scaling a bank's output before it mixes into
  # the voice sat on the saw's row, and the bank's unnamed param_1 was the
  # default pick
  it 'puts a knob on the row whose output it scales, and never picks an unnamed input first' do
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.knob(:breath, 0.35)
      MB::Sound.knob(:hold, 0.3)
      MB::Sound.track(:t) { |c|
        c.synth { |v|
          breath = MB::Sound.noise.bandpass_series(v.hz.freq, count: 4) * MB::Sound.knob(:breath) * (MB::Sound.knob(:hold) + (1 - MB::Sound.knob(:hold)) * v.env(0.005, 0.25, 0, 0.1))
          (v.hz.saw + breath * 4).formant(:u, :a, morph: 0.4) * v.amp_env
        }
      }
      MB::Sound.bg(:t, MB::Sound.seq(MB::Sound::C3).n4.loop, on: :now)
    end
    4.times { @session.process_buffer }
    g = ui::Inspect::Gatherer.new
    info = g.call(@session, { track: :t, node: nil })
    on = ->(kn) { info.nodes.find { |n| n.params.values.any? { |p, _| n.knob_of(p) == kn } }&.label }
    expect(on.(:breath)).to eq('bandpass_series')
    expect(on.(:hold)).to eq('bandpass_series')
    pane = ui.panes.fetch(:inspector)
    st = {}
    list = pane.send(:pick_list, st, info)
    stop = list[pane.send(:stop_index, st, info, list)]
    expect(stop[1].to_s).not_to match(/\Aparam_\d+\z/)
  end
end

require_relative '../../../../support/ui_helpers'
require_relative '../../../../support/allocation_budget'

# The painter's garbage per frame (ui-perf-1, 2026-11-16): painter garbage
# collections hold the GVL and delay the render thread (the sibling branch
# ui-wave-perf-1 measured 0 waits over 2 ms with a zero-allocation draw
# path).  These budgets cap the objects one steady-state frame allocates,
# per layout, with snapshots that change every frame (the scope's samples,
# the meters' peaks, the clock), so a new pane feature can't quietly add
# garbage.  ALLOC_REPORT=1 prints the top sites; a failure names them.
#
# Measured on the Linux container (objects per frame, before -> after
# ui-perf-1's painter changes): band 341 after (its scope is the same plot
# path, 90 KB a frame), tiles 455
# -> 394 (the scope's plot path, Plot::Live and plot/mark.rb, is 190 of
# them and 72 KB of Numo arrays a frame: the sibling branch's), sound with
# the inspector focused 439 -> 374 (the inspector's rows, sound_panes.rb,
# are 205).  Second round (the transport and meters panes and the status
# line as text calls with kept strings; string literals in files without
# the frozen-string-literal comment allocate each time, so the painter's
# use -'text'): band 341 -> 281, tiles 394 -> 320, sound 374 -> 328.
# ui-perf-2 (the combined branches: the inspector rows kept by value, and
# the live scope drawn by Plot::Live#retrace without a chart): band 65,
# tiles 105, sound 105.  ui-perf-2 round 3: the meters' zone lookup
# returned out of a block (an imemo per meter cell, 77 a frame, which the
# site table can't show: count_objects or dump_all does): band 25, tiles
# 26; fit and pad written into the grid (Canvas#text_fit, #text_pad,
# #run_pad), the inspector's rows, the picker, the status line, and the
# Code pane kept while their inputs stay: band 18, tiles 22, sound 17,
# and with a knob moving every frame 170 -> 50.  The budgets sit about
# 15-20 % above the after numbers.
RSpec.describe('the painter\'s allocations per frame', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  BUDGETS = { band: 22, tiles: 26, sound: 20, sweep: 60 }.freeze

  after do
    ui::Inspect.target = nil
    @tiles&.stop
    @term&.close
    @session&.close
    MB::Sound.rewind
  end

  def moving_snaps(extra = {})
    Array.new(240) { |i| ui_fake_snapshot(t: 1.0 + i / 60.0, seq: i + 1, scope_phase: i * 0.1, peak: -8.0 - (i % 7)).with(**extra) }
  end

  def measure_tiles(layout, snaps, focus: nil)
    frame = 0
    @term = UIHelpers::FakeTerminal.new(40, 140)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(layout), input: @term.slave, output: @term.slave, repl: :none,
                           probe: false, size: [40, 140], clock: -> { 1.0 + frame / 60.0 }, source: -> { snaps[frame % snaps.length] },
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    # The picker's head and path cache renews every Picker::KEEP seconds
    # (2), so a renewal could land in the measured frames: an earlier
    # example's cache aging out there gave 50 objects a frame from
    # Library::Index#all_entries and Library.document_paths (the sound
    # screen, seed 47008 of the UI directory on a loaded machine; the same
    # guard as inspector_allocations_spec's).  The detail line's memo
    # starts empty too, so the warm-up keeps the picked entry's line.
    stub_const('MB::Sound::UI::Picker::KEEP', 1e9)
    ui::Picker.instance_variable_set(:@cache, nil)
    details = ui::Panes::Picker::DETAILS
    details.keys.each { |k| details.delete(k) }
    @tiles.start(thread: false)
    @tiles.enter(focus) if focus
    80.times { frame += 1; @tiles.refresh } # (warm: caches, first draws)
    AllocationBudget.measure(buffers: 120) { frame += 1; @tiles.refresh }
  end

  it 'keeps the band under its budget' do
    snaps = moving_snaps
    i = 0
    band, = ui_fake_band(:band) { snaps[(i += 1) % snaps.length] }
    80.times { |k| band.refresh(1.0 + k / 60.0) }
    m = AllocationBudget.measure(buffers: 120) { band.refresh(3.0 + i / 60.0) }
    puts m.report(15) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= BUDGETS[:band], m.report
  end

  it 'keeps the tiles (a moving scope and meters) under their budget' do
    m = measure_tiles(:tiles, moving_snaps)
    puts m.report(15) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= BUDGETS[:tiles], m.report
  end

  def sound_setup
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.bg(:bass, MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop)
    end
    4.times { @session.process_buffer }
    ui::Inspect.target = { track: :bass, node: nil }
    slow, = ui::Poll.new(@session).call([:inspect])
    knobs = @session.knobs.map { |n, k| ui::KnobValue.new(name: n, value: k.value, spec: k.spec) }.freeze
    [slow, knobs]
  end

  it 'keeps the sound screen (the inspector focused, snapshots moving) under its budget' do
    slow, knobs = sound_setup
    m = measure_tiles(:sound, moving_snaps(slow: slow, knobs: knobs), focus: :inspector)
    puts m.report(15) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= BUDGETS[:sound], m.report
  end

  # A knob turning every frame (a sweep: the feed gives a new KnobValue
  # for the turned knob and keeps the others): the inspector's value
  # texts, the row's tail, and the Code pane's knob line are rebuilt,
  # nothing else
  it 'keeps the sound screen under its budget with a knob moving every frame' do
    slow, knobs = sound_setup
    i0 = knobs.index { |k| k.name.to_s.end_with?('cutoff') } || 0
    kv = knobs[i0]
    snaps = Array.new(240) { |i|
      ks = knobs.dup
      ks[i0] = kv.with(value: kv.spec.range.begin.to_f + (kv.spec.range.end.to_f - kv.spec.range.begin.to_f) * (i % 60) / 60.0)
      ui_fake_snapshot(t: 1.0 + i / 60.0, seq: i + 1).with(slow: slow, knobs: ks.freeze)
    }
    m = measure_tiles(:sound, snaps, focus: :inspector)
    puts m.report(15) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= BUDGETS[:sweep], m.report
  end
end

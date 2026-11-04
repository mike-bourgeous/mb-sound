require_relative '../../../../support/ui_helpers'

# The inspector's live data between the 4/s polls (inspector-nav-1; the
# maintainer, 2026-11-02: "Envelope preview play head sometimes just stops
# updating even though the UI heading says it's at 60fps"): the selected
# envelope's playhead is read again every frame (Gatherer#live_info, through
# Poll#live_again and Follow#poll), and a key that picks another row gets
# its info at once (Poll#inspect_again), not at the next poll.
RSpec.describe('UI inspector live data', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    allow(ui).to receive(:show) { nil }
    allow(ui::Design).to receive(:terminal?).and_return(false)
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
  end

  after do
    ui::Inspect.target = nil
    ui::Design.instance_variable_set(:@open, false)
    ui::Design.instance_variable_set(:@last, nil)
    @session&.close
    MB::Sound.rewind
  end

  # His line: acid on eighth notes gated half way, at 120 BPM four notes a
  # second, the poll's own rate.
  def design_acid
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.module_eval('design :bass, L.inst.acid, seq(E1, E1, G1, A1).n8.loop.legato(0.5)')
    end
    20.times { @session.process_buffer }
  end

  it 'reads the envelope playhead every frame, where a 4/s poll saw one moment of each note' do
    design_acid
    g = ui::Inspect::Gatherer.new
    info = g.call(@session, { track: :bass })
    amp = info.nodes.index { |n| n.what == 'amp env' }
    expect(amp).not_to be_nil
    info = g.call(@session, { track: :bass, node: amp })
    expect(info.selected.live).not_to be_nil
    polled = []
    framed = []
    # 2 s: a poll every 0.25 s (15 buffers of 800), a frame every buffer
    60.times do |i|
      @session.process_buffer
      info = g.call(@session, { track: :bass, node: amp }) if i % 15 == 0
      l = info.selected.live
      polled << [l[:stage], l[:position]&.round(3)] if i % 15 == 0
      fresh = g.live_info(info)
      l = fresh.selected.live
      framed << [l[:stage], l[:position]&.round(3)]
      expect(fresh.nodes.length).to eq(info.nodes.length)
      expect(fresh.track).to eq(:bass)
    end
    # (every poll lands on the same moment of a note: the playhead stood still)
    expect(polled.uniq.length).to be <= 2
    expect(framed.uniq.length).to be >= 8
    expect(framed.map(&:first).uniq).to include(:segment)
    expect(Ractor.shareable?(g.live_info(info))).to eq(true)

    # A row without a playhead (the diode): the same info, no new objects
    diode = info.nodes.index { |n| n.label == 'diode' }
    other = g.call(@session, { track: :bass, node: diode })
    expect(g.live_info(other)).to equal(other)
  end

  it 'polls slow data every POLL seconds, the playhead between, and the inspector again when the target changes' do
    calls = []
    slow = ui::Snapshot.fake.slow.with(inspector: :info)
    fake = Object.new
    fake.define_singleton_method(:call) { |_needs| calls << :call; [slow, []] }
    fake.define_singleton_method(:live_again) { |slow| calls << :live; slow }
    fake.define_singleton_method(:inspect_again) { |slow| calls << :again; slow }
    feed = ui::Feed.new
    feed.needs = [:inspect]
    screen = Object.new
    screen.extend(ui::Follow)
    screen.instance_variable_set(:@poll, fake)
    screen.instance_variable_set(:@feed, feed)
    screen.instance_variable_set(:@polled_at, nil)
    screen.instance_variable_set(:@polled_target, nil)
    poll = ->(t) { screen.send(:poll, t) }
    ui::Inspect.target = { track: :bass, node: 1 }.freeze
    poll.(0.0)
    poll.(0.016)
    poll.(0.032)
    ui::Inspect.target = { track: :bass, node: 2 }.freeze
    poll.(0.048)
    poll.(0.064)
    poll.(0.26)
    expect(calls).to eq(%i[call live live again live call])
  end
end

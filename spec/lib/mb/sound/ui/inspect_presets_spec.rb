require_relative '../../../../support/ui_helpers'

# Every shipped instrument preset, played on a track, shows every node an
# inspector row could show, in sections with no node unfit (the sections
# guard, sound-design-nav-1; omnibus15; research-sound-design-nav found
# tine_piano and tine_crunch listing one node: their root is a
# ChannelMixer, which has no #graph, so UI::Inspect.walk stopped there).
# The rows' node groups must cover the inspectable nodes of the player's
# whole graph (GraphNode.graph from each of its outputs).
RSpec.describe(MB::Sound::UI::Inspect, :aggregate_failures) do
  let(:inspect) { described_class }

  # Nodes a row could show (Inspect.walk's own filter).
  def inspectable?(n)
    return false if n.is_a?(Numeric) || !n.respond_to?(:param_info) || inspect::SKIP.include?(n.class.name)
    !n.param_info.empty? || inspect.preview?(n)
  end

  ENTRIES = MB::Sound::Library.index.entries(kind: :instrument).select { |e| e.location.to_s.include?('/presets/') }.map(&:name)
  CLIP = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop
  BEAT = MB::Sound.seq(*(35..81).to_a).n16.loop # (every GM drum note: any kit's voices)

  it 'sweeps the shipped instrument presets' do
    expect(ENTRIES.length).to be >= 30
    expect(ENTRIES).to include(:tine_piano, :tine_crunch, :dnb_reese)
  end

  # The sections guard (sound-design-nav-1): every node lands in a
  # section or is plumbing (none unfit), envelopes sit in the section they
  # shape (an amp envelope in AMP, a filter envelope in FILTER), and the
  # inspector opens on a row.
  def expect_sections(walked)
    nodes = walked[:nodes]
    expect(walked[:unfit]).to eq(0)
    shown = nodes.reject { |n| n.section == :plumbing }
    expect(shown).not_to be_empty
    expect(shown.map(&:section) - inspect::SECTIONS).to eq([])
    { 'amp env' => :amp, 'filter env' => :filter, 'pitch env' => :source }.each do |what, sec|
      expect(shown.select { |n| n.what == what }.map(&:section).uniq - [sec]).to eq([]), "#{what} outside #{sec}"
    end
    expect(inspect.default_node(nodes, walked[:voices].first)).not_to be_nil
  end

  # Reasons an oscillator row may give instead of its cycle (the render
  # pane's too: a voice there is no copy of).
  TONE_CYCLE_REASONS = /no recorded call to copy|outside the voice|no synth voice to copy|shared with the live graph/

  # The oscillator preview's sweep (ux-notes-2, UI::ToneCycle): every
  # SOURCE oscillator row renders one cycle (finite, one period at its
  # frequency, or a noise window) or says why it can't.  The render
  # pane's Source is built as UI::Poll#render_source builds it.
  def expect_tone_cycles(name, input, walked, clip)
    tc = MB::Sound::UI::ToneCycle
    roots = inspect.roots(input)
    nodes = roots.flat_map { |r| [r, *(r.respond_to?(:graph) ? r.graph(include_tees: true) : [])] }.uniq(&:__id__)
    synth = nodes.find { |n| n.is_a?(MB::Sound::Synth) }
    live = nodes.to_h { |n| [n.__id__, true] }
    synth&.instance_variable_get(:@lane_graphs)&.each { |g| g.each { |n| live[n.__id__] = true } }
    src = MB::Sound::UI::PatchRender::Source.new(track: :t, synth: synth, clip: clip, bpm: 120, bar_length: 1r, key: nil, tuning: nil, channels: 2,
                                                 note: synth ? nil : 't has no synth voice to copy', words: name.to_s, live: live)
    input_note = MB::Sound::UI::PatchRender.input(src, 0.5)
    cache = {}
    walked[:nodes].each_index do |i|
      next unless walked[:nodes][i].section == :source && walked[:objects][i].is_a?(MB::Sound::Tone)
      label = "#{name} #{walked[:nodes][i].label}"
      r = tc.render(tc::Job.new(seq: i, key: [i], source: src, input: input_note, knobs: [], tone: tc.key_of(walked[:objects][i])), cache: cache)
      if r.error
        expect(r.error).to match(TONE_CYCLE_REASONS), label
        next
      end
      expect(r.cycle.length).to be > 1, label
      expect(r.cycle.isfinite.all?).to eq(true), label
      want = r.noise ? tc::NOISE_FRAMES : r.partial ? (tc::MAX_SECONDS * r.rate).round : (r.rate / r.frequency).ceil + 1
      expect(r.frames).to eq(want), label
    end
  ensure
    cache&.[](:copies)&.each_value(&:close)
    cache&.[](:scopes)&.each_value(&:close)
  end

  # The navigation guard (inspector-nav-1; the maintainer, 2026-11-02:
  # "Arrow key up/down navigation in the inspector is pretty flaky ...
  # Doesn't loop around from very top to very bottom"): in the sections
  # view, Down from the first stop visits every stop of the pick list once
  # and comes back, Up the same in reverse, with the inspector's info
  # polled after each key and (Up) never between keys (presses faster than
  # the 4/s poll); the picked stop is always on screen (its reversed text
  # drawn) at a tall, a middling, and a short pane; and the rows the pane
  # draws (all open, tall) are the rows the list steps, in its order.
  def expect_navigation(session, label, track: :t)
    ui = MB::Sound::UI
    pane = ui.panes.fetch(:inspector)
    gatherer = ui::Inspect::Gatherer.new
    ui::Inspect.target = { track: track }
    snap = -> { ui::Snapshot.fake(slow: ui::Snapshot.fake.slow.with(inspector: gatherer.call(session)), knobs: session.knobs.values.map { |k| ui::KnobValue.new(name: k.name, value: k.value, spec: k.spec) }) }
    draw = lambda do |st, s, w, h|
      grid = MB::Term::Cells.new(w, h)
      pane.draw(ui::Canvas.new(grid, 0, 0, w, h), s, st)
      attrs = grid.instance_variable_get(:@attr)
      rev = (0...h).filter_map { |y| t = (0...w).select { |x| attrs[y * w + x] & MB::Term::Cells::REVERSE != 0 }.map { |x| grid.char(x, y) }.join.strip; t.empty? ? nil : t }
      [grid.to_text(:none).lines.map(&:rstrip), rev]
    end
    s = snap.()
    info = s.inspector
    return if info.nil? || !info.sections?
    st = { title_in_rule: true, mode: true }
    draw.(st, s, 60, 30)
    list = pane.send(:pick_list, st, info)
    keys = list.map { |e| pane.send(:stop_key, e) }
    expect(keys.uniq.length).to eq(keys.length), "#{label}: stops twice in the list"
    start = st[:at]
    shown_text = lambda do |e|
      text = case e[0]
             when :param then e[1].to_s
             when :knob then e[1].to_s
             else pane.send(:row_title, info.nodes[e[3]])
             end
      text[0, 6]
    end
    [[1, true], [-1, false]].each do |d, poll|
      seen = []
      list.length.times do
        pane.key_action(:pick, st, d)
        s = snap.() if poll
        seen << st[:at]
        e = list[keys.index(st[:at])]
        [[60, 30], [52, 14], [48, 8]].each do |w, h|
          lines, rev = draw.(st, s, w, h)
          expect(rev.any? { |r| r.start_with?(shown_text.(e)) }).to eq(true), "#{label}: #{e[0]} #{e[1] || pane.send(:row_title, info.nodes[e[3]])} not on screen at #{w}x#{h} (reversed: #{rev.inspect})\n#{lines.join("\n")}"
        end
      end
      expect(seen.last).to eq(start), "#{label}: #{d > 0 ? 'Down' : 'Up'} #{list.length} times didn't come back"
      expect(seen.uniq.length).to eq(list.length), "#{label}: #{d > 0 ? 'Down' : 'Up'} missed stops"
      want = d > 0 ? keys.rotate(keys.index(start) + 1) : keys.rotate(keys.index(start)).reverse
      expect(seen).to eq(want), "#{label}: #{d > 0 ? 'Down' : 'Up'} out of display order"
    end
    # (one list: the rows drawn, every row open, are the rows stepped)
    lines, = draw.(st, snap.(), 100, 80)
    fit = ui::Canvas.new(MB::Term::Cells.new(1, 1), 0, 0, 1, 1)
    titles = info.nodes.each_index.to_h { |i| [i, fit.pad(pane.send(:row_title, info.nodes[i]), 14).rstrip] }
    drawn = lines.filter_map { |l| l[1, 14].to_s.rstrip if l.match?(/\A[ ▸]\S/) && titles.value?(l[1, 14].to_s.rstrip) }
    stepped = list.map { |e| e[3] }.compact.uniq.map { |i| titles[i] }
    expect(drawn).to eq(stepped), "#{label}: rows drawn vs rows stepped\n#{lines.join("\n")}"
  ensure
    MB::Sound::UI::Inspect.target = nil
  end

  %i[tr909 tr808].each do |kit|
    it "classifies every node of the #{kit} kit, by voice" do
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.instance_exec(kit) { |k| track(:t) { |c| send(k, c) } }
        MB::Sound.bg(:t, BEAT)
      end
      4.times { session.process_buffer }
      input = session.instance_variable_get(:@players).values.find { |p| p.name == :t }.input
      walked = inspect.walk(inspect.roots(input))
      expect_sections(walked)
      expect(walked[:voices]).to include(:kick, :snare)
      expect(walked[:voice_knobs].keys).to match_array(walked[:voices]) # (each voice's knob values, for the strip under the voices)
      expect(walked[:voice_knobs][:kick]).to include(:tune, :decay)
      expect(Ractor.shareable?(walked[:voice_knobs])).to eq(true)
      expect(walked[:nodes].reject { |n| n.section == :plumbing }.map(&:voice).uniq.compact).to eq(walked[:voices])
      expect_navigation(session, kit)
      # (sound-design-2: each voice opens on its body, its resonator or
      # source, not its first filter)
      walked[:voices].each do |v|
        i = inspect.default_node(walked[:nodes], v, objects: walked[:objects])
        n = walked[:nodes][i]
        expect([v, nil]).to include(n.voice)
        expect(walked[:objects][i].is_a?(MB::Sound::GraphNode::Resonator) || n.section == :source).to eq(true), "#{kit} #{v} opens on #{n.label} (#{n.section})"
      end
    ensure
      session&.close
      MB::Sound.rewind
    end
  end

  # The other instrument families (inspector-nav-1: acid's accent node fit
  # no section, so its row wasn't drawn, and Down stopped on it): struck
  # instruments and genre patches, made with `track :t, entry`.
  OTHERS = MB::Sound::Library.index.entries(kind: :instrument).reject { |e| e.location.to_s.include?('/presets/') }

  it 'sweeps the struck instruments and genre patches too' do
    expect(OTHERS.map(&:name)).to include(:acid, :house_bass, :bell, :marimba)
  end

  OTHERS.each do |entry|
    it "classifies #{entry.name} (#{entry.family}) in sections and steps its rows" do
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.track(:t, entry)
        MB::Sound.bg(:t, CLIP)
      end
      2.times { session.process_buffer }
      input = session.instance_variable_get(:@players).values.find { |p| p.name == :t }.input
      walked = inspect.walk(inspect.roots(input))
      expect_sections(walked)
      expect_navigation(session, entry.name)
    ensure
      session&.close
      MB::Sound.rewind
    end
  end

  ENTRIES.each do |name|
    it "lists every inspectable node of #{name}" do
      # (drum kits take drum notes: a kit raises SourceMismatch on the
      # melodic clip, and the track is made again on every GM drum note;
      # before fuzz-fixes-2 every preset was built once more first to find
      # out, about a tenth of this file's time)
      source = CLIP
      session = nil
      begin
        session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
        begin
          MB::Sound::Session.with_context(session: session) do
            MB::Sound.instance_exec(name) { |n| track(:t) { |c| preset n, midi: c } }
            MB::Sound.bg(:t, source)
          end
        rescue MB::Sound::GraphIO::LoadError => err
          raise unless err.message.include?('SourceMismatch') && source.equal?(CLIP)

          session.close
          MB::Sound.rewind
          source = BEAT
          session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
          retry
        end
        2.times { session.process_buffer }
        input = session.instance_variable_get(:@players).values.find { |p| p.name == :t }.input
        walked = inspect.walk(inspect.roots(input))
        expect(walked[:nodes].length).to be > 1
        expect_sections(walked)
        next if walked[:capped] # (rows capped: coverage can't be told)

        expect_tone_cycles(name, input, walked, source)
        expect_navigation(session, name)

        shown = walked[:groups].flatten.to_h { |n| [n.object_id, true] }
        whole = (input.respond_to?(:nodes) ? input.nodes : [input]).flat_map { |n| MB::Sound::GraphNode.graph(n) }.uniq(&:object_id)
        missing = whole.select { |n| inspectable?(n) && !shown[n.object_id] }
        expect(missing.map { |n| inspect.label_of(n) }).to eq([]), "#{walked[:nodes].length} rows miss #{missing.length} nodes"
      ensure
        session.close
        MB::Sound.rewind
      end
    end
  end
end

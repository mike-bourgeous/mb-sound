require_relative '../../../../support/ui_helpers'

# Note 15 (the maintainer, 2026-10-31): "Every parameter should be
# editable in the sound design inspector".  The editability guard
# (editability-1): every param the inspector shows on every shipped
# instrument preset and on the tr909 and tr808 kits is a knob, a bind away
# from one (its Bind has a line; a sample of those lines is test-built,
# Arrangement#bind_probe, so an offered line that a knob can't follow
# fails here), driven by a node, a count (read-only by the maintainer's
# choice), or a gap of a kind listed below with its reason.  A new gap
# fails, naming the preset, row, param, and the reason the inspector gives.
RSpec.describe('Inspector editability (Note 15)', :aggregate_failures) do
  let(:inspect) { MB::Sound::UI::Inspect }
  let(:lb) { MB::Sound::Arrangement::LiteralBinding }

  EDIT_ENTRIES = MB::Sound::Library.index.entries(kind: :instrument).select { |e| e.location.to_s.include?('/presets/') }.map(&:name)
  EDIT_CLIP = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop
  EDIT_BEAT = MB::Sound.seq(*(35..81).to_a).n16.loop # (every GM drum note: any kit's voices)

  # Kinds of gaps left for later pieces of the maintainer's option 2
  # ("library code takes params"), by the reason the inspector gives.
  GAP_KINDS = {
    # A drum voice's own nodes (an 808 hat's bandpass): the voice's
    # settings are its row's, bindable; the numbers inside its code aren't
    # settings yet.
    kit_internals: ->(_preset, reason) { reason.match?(/\A\w+: set inside the \w+ [\w ]+'s code; its settings are the \w+ row's \(/) },
    # SQ-80 presets build their voices in library code (MB::Sound::SQ80);
    # their params are knobs, their other numbers wait for the SQ-80 work
    # (banned from demos until the maintainer lifts it).
    sq80: ->(preset, reason) { preset.to_s.start_with?('sq80_') && reason.match?(/is fixed in the sq80_\w+ preset/) },
  }.freeze

  # Single gaps, by [preset, row, param], with why.
  KNOWN = {
    # Vibrato LFOs made inside `v.hz.vibrato(rate, depth:)` (a NotePitch
    # setting, built where the pitch is used): no recorded call makes the
    # sine, and the vibrato call is on a NotePitch, which isn't in the
    # graph.  A voice helper that takes params (option 2) would bind them.
    [:digibrass, 'sine', :frequency] => 'vibrato internals', [:digibrass, 'sine', :phase] => 'vibrato internals',
    [:funk_choir, 'sine', :frequency] => 'vibrato internals', [:funk_choir, 'sine', :phase] => 'vibrato internals',
    [:funk_talkbox, 'sine', :frequency] => 'vibrato internals', [:funk_talkbox, 'sine', :phase] => 'vibrato internals',
    [:jungle_flute, 'sine', :frequency] => 'vibrato internals', [:jungle_flute, 'sine', :phase] => 'vibrato internals',
    [:jungle_pad, 'triangle', :frequency] => 'vibrato internals', [:jungle_pad, 'triangle', :phase] => 'vibrato internals',
    # Notes#lfo's offset (`v.lfo(2.bars, depth: 0.8)`): an internal of
    # the voice lfo, not one of its keywords.
    [:dnb_neuro, 'lfo', :constant] => 'Notes#lfo internals', [:dnb_reese, 'lfo', :constant] => 'Notes#lfo internals',
    [:funk_talkbox, 'lfo', :constant] => 'Notes#lfo internals',
    [:dnb_neuro, 'phasor', :phase] => 'Notes#lfo internals',
    # A lowpass inside a feedback loop whose row's first node has a call
    # recorded without an ordinal (one of the copies; the others have
    # keys): to investigate.
    [:ambient_harp, 'lowpass', :quality] => 'call key missing on a copy', [:ambient_koto, 'lowpass', :quality] => 'call key missing on a copy',
  }.freeze

  # One bind line test-built per preset (each a full patch build, about
  # 0.2-0.7 s), chosen by the preset's name, so the run covers different
  # kinds of lines across presets: the same one every run.
  def pick(name, lines)
    lines.empty? ? [] : [lines[name.to_s.sum % lines.length]]
  end

  # [[preset, row, param, reason], ...] of the gaps in track :t's
  # inspector, and the bind lines probed that failed.
  def gaps(session, name)
    g = inspect::Gatherer.new
    info = g.call(session, { track: :t, node: nil })
    voices = info.voices.empty? ? [nil] : info.voices
    out = []
    lines = []
    seen = {}
    voices.each do |voice|
      g.call(session, { track: :t, node: nil, voice: voice }).shown.each do |i|
        n = g.call(session, { track: :t, node: i, voice: voice }).nodes[i] or next
        n.params.values.each do |pname, v|
          next if n.section && v.value.nil? && MB::Sound::UI::Panes::Inspector::NOTE_PARAMS.include?(pname)
          next if seen[[n.section, n.label, n.voice, pname]]
          seen[[n.section, n.label, n.voice, pname]] = true
          next if n.knob_of(pname)
          next unless v.detail == inspect::LITERAL || (v.detail.nil? && v.value.is_a?(Numeric))
          next if lb.count?(pname, v.value)
          b = n.binds&.[](pname)
          if b&.line
            lines << b.line
            next
          end
          reason = b&.reason || 'no bind offered'
          next if GAP_KINDS.any? { |_, ok| ok.(name, reason) } || KNOWN.key?([name, n.label, pname])
          out << [name, n.label, pname, reason]
        end
      end
    end
    [out, lines]
  end

  # Test-builds bind +line+ on track :t, returning nil or the error.
  def probe(session, line)
    m = line.match(/\Abind :t, (?:(\w+): :(\w+)|:(\w+))(?:, nth: (\d+))?(?:, as: :"([^"]+)")?\z/) or return "unparsed: #{line}"
    roots = inspect.roots(session.ui_graphs[:t])
    t = m[3] ? lb.find_document(roots, m[3].to_sym) : lb.find(roots, m[1].to_sym, m[2].to_sym, m[4].to_i)
    kname = m[5] ? m[5].to_sym : lb.knob_name(:t, t, roots).first
    got = session.arrangement.bind_probe(:t, session.arrangement.tracks[:t], t, kname, lb.knob_default(t.param, t.value, lb.kit_range(t)))
    got.is_a?(Exception) ? "#{line}: #{got.message}" : nil
  end

  def check(name, &build)
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session, &build)
    2.times { session.process_buffer }
    found, lines = gaps(session, name)
    expect(found).to eq([]), "#{name}: #{found.length} params the inspector shows but can't edit:\n#{found.map(&:inspect).join("\n")}"
    picks = pick(name, lines)
    expect(picks.filter_map { |l| probe(session, l) }).to eq([]), name.to_s
  ensure
    session&.close
    MB::Sound.rewind
  end

  it 'covers the shipped presets and kits' do
    expect(EDIT_ENTRIES).to include(:tine_piano, :tine_crunch, :dnb_reese, :dnb_drums, :init)
  end

  %i[tr909 tr808].each do |kit|
    it "edits every param of the #{kit} kit or lists the gap" do
      check(kit) do
        MB::Sound.instance_exec(kit) { |k| track(:t) { |c| send(k, c) } }
        MB::Sound.bg(:t, EDIT_BEAT)
      end
    end
  end

  # kit-live-1 (the maintainer's "Yes, live kit knobs", 2026-11-02):
  # every voice setting of the kits binds as a live knob, one the playing
  # kit follows (sweeps, follows, MIDI), never a build knob a turn
  # rebuilds the kit for: the kit is given the knob and reads it as a node.
  # Every setting's bind is test-built (Arrangement#bind_probe), so a voice
  # that reads a setting once while building (a number in Ruby
  # arithmetic, an Integer count) fails here, naming the voice and setting.
  EDIT_KITS = {
    tr909: ->(c) { MB::Sound.tr909(c) },
    tr808: ->(c) { MB::Sound.tr808(c) },
    dnb_drums: :dnb_drums, funk_beat: :funk_beat, funk_perc: :funk_perc, jungle_perc: :jungle_perc,
    machine: ->(c) { MB::Sound.kit(c) { voice(:kick, tune: 48, decay: 0.4) { |h| h.body(h.tune, decay: h.decay) + h.click(0.3) }; tr909 :snare, :clap; tr808 :cowbell, :closed_hat } },
  }.freeze

  EDIT_KITS.each do |kname, patch|
    it "binds every voice setting of the #{kname} kit as a live knob" do
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: session) do
        patch.is_a?(Symbol) ? MB::Sound.track(:t, patch) : MB::Sound.track(:t, &patch)
        MB::Sound.bg(:t, EDIT_BEAT)
      end
      2.times { session.process_buffer }
      roots = inspect.roots(session.ui_graphs[:t])
      kit = lb.nodes(roots).find { |n| n.is_a?(MB::Sound::Drums::Kit) }
      expect(kit).not_to be_nil
      checked = 0
      refused = []
      kit.voices.each do |vname, voice|
        voice.param_info.each_key do |setting|
          next unless lb.literal?(voice.knobs[setting])
          t = lb.target(roots, kit, :"#{vname}_#{setting}")
          knob = lb.knob_name(:t, t, roots).first
          got = session.arrangement.bind_probe(:t, session.arrangement.tracks[:t], t, knob, lb.knob_default(t.param, t.value, lb.kit_range(t)))
          checked += 1
          refused << [vname, setting, got.is_a?(Exception) ? got.message : 'a build knob'] if got.is_a?(Exception) || got.build?
        end
      end
      expect(checked).to be > 10
      expect(refused).to eq([]), "#{kname}: voice settings that aren't live knobs:\n#{refused.map(&:inspect).join("\n")}"
    ensure
      session&.close
      MB::Sound.rewind
    end
  end

  # gen-knobs-1: a library generator's steering params are its track's
  # knobs (:"t/energy"), shown on the notes row as knob params (never loose
  # knobs), for every shipped generator that has them.
  it 'shows every shipped generator\'s track knobs as knob params of its notes row' do
    gens = MB::Sound::Library::Generators
    entries = MB::Sound::L.gen.entries.reject { |e| gens.knob_params(e).empty? }
    expect(entries.length).to be >= 6
    entries.each do |e|
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.track(:t, e)
        MB::Sound.bg(:t, on: :now)
      end
      2.times { session.process_buffer }
      info = inspect::Gatherer.new.call(session, { track: :t, node: nil })
      row = info.nodes.find { |n| n.what == 'notes' }
      expect(row&.label).to eq(e.name.to_s)
      knobs = gens.knob_params(e).map { |p| :"t/#{p}" }
      expect(gens.knob_params(e).map { |p| row&.knob_of(p) }).to eq(knobs), e.name.to_s
      expect(info.loose & knobs).to eq([]), e.name.to_s
    ensure
      session&.close
      MB::Sound.rewind
    end
  end

  EDIT_ENTRIES.each do |name|
    it "edits every param of #{name} or lists the gap" do
      source = begin
        MB::Sound.keeping_random_state { MB::Sound.preset(name, midi: EDIT_CLIP) }
        EDIT_CLIP
      rescue MB::Sound::GraphIO::LoadError => err
        raise unless err.message.include?('SourceMismatch')
        EDIT_BEAT
      end
      check(name) do
        MB::Sound.track(:t, name)
        MB::Sound.bg(:t, source)
      end
    end
  end
end

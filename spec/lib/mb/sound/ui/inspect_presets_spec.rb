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
    ensure
      session&.close
      MB::Sound.rewind
    end
  end

  ENTRIES.each do |name|
    it "lists every inspectable node of #{name}" do
      # (drum kits take drum notes)
      source = begin
        MB::Sound.keeping_random_state { MB::Sound.preset(name, midi: CLIP) }
        CLIP
      rescue MB::Sound::GraphIO::LoadError => err
        raise unless err.message.include?('SourceMismatch')
        BEAT
      end
      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      begin
        MB::Sound::Session.with_context(session: session) do
          MB::Sound.instance_exec(name) { |n| track(:t) { |c| preset n, midi: c } }
          MB::Sound.bg(:t, source)
        end
        2.times { session.process_buffer }
        input = session.instance_variable_get(:@players).values.find { |p| p.name == :t }.input
        walked = inspect.walk(inspect.roots(input))
        expect(walked[:nodes].length).to be > 1
        expect_sections(walked)
        next if walked[:capped] # (rows capped: coverage can't be told)

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

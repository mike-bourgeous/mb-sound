require_relative '../../../../support/ui_helpers'

# Every shipped instrument preset, played on a track, shows every node an
# inspector row could show (omnibus15; research-sound-design-nav found
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
        next if walked[:nodes].length >= inspect::MAX_NODES # (rows capped: coverage can't be told)

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

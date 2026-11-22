require 'prism'

# Sessions that library code makes for itself (warm-up sandboxes, offline
# renders, take replays, patch previews) pass their own Transport: one left
# on the default would advance the shared timeline that the console and
# song scripts play on (fix-script-ui-meters: warm_up_slots' sandbox moved
# it to 4/125 before a song started, so the song's loops waited for bar 2
# and a one-bar `--ui` run was silent; specs missed it because warm_up
# runs its steps only under YJIT).  This reads lib/ with Prism and fails
# any `Session.new` without a `transport:` keyword that isn't in ALLOWED.
# (The default Session, made by Session.current with a bare `new`, owns
# the shared transport.)
module SandboxSessions
  ROOT = File.expand_path('../../../..', __dir__)

  # [file, reason] for calls whose transport comes another way.
  ALLOWED = {
    'lib/mb/sound/ui/patch_render.rb' => 'scope_for passes **opts, which always holds its own Transport (the source\'s tempo and key)',
  }.freeze
end

RSpec.describe('Sessions made in lib/') do
  # [relative path, line] of each Session.new in +path+ without transport:.
  def bare_sessions(path)
    rel = path.delete_prefix("#{SandboxSessions::ROOT}/")
    found = []
    stack = [Prism.parse_file(path).value]
    while (n = stack.pop)
      if n.is_a?(Prism::CallNode) && n.name == :new && n.receiver&.slice&.match?(/(\A|::)Session\z/)
        keys = (n.arguments&.arguments || []).flat_map { |a|
          a.is_a?(Prism::KeywordHashNode) ? a.elements.filter_map { |e| e.key.unescaped.to_sym if e.respond_to?(:key) && e.key.is_a?(Prism::SymbolNode) } : []
        }
        found << [rel, n.location.start_line] unless keys.include?(:transport)
      end
      stack.concat(n.compact_child_nodes)
    end
    found
  end

  it 'pass their own transport' do
    found = Dir[File.join(SandboxSessions::ROOT, 'lib/**/*.rb')].sort.select { |f| File.read(f).include?('Session.new') }.flat_map { |f| bare_sessions(f) }
    bad = found.reject { |rel, _| SandboxSessions::ALLOWED.key?(rel) }
    expect(bad.map { |rel, line| "#{rel}:#{line}" }).to eq([]),
      "Session.new without transport: (give it Sequence::Transport.new, or list it in SandboxSessions::ALLOWED with why):\n" \
      "#{bad.map { |rel, line| "  #{rel}:#{line}" }.join("\n")}"
  end

  it 'still finds the allowed calls (no stale entries)' do
    SandboxSessions::ALLOWED.each_key do |rel|
      expect(bare_sessions(File.join(SandboxSessions::ROOT, rel))).not_to be_empty, "#{rel} has no Session.new without transport: any more"
    end
  end
end

require 'prism'

# Every change the UI makes to a performance goes through a console
# command run by UI.run_line, so it is journaled, undoable, and a line of
# the take that replays it (ux-1: KEYS Enter's capture and step entry's
# swap called Arrangement methods on UI threads and were missing from
# takes).  This guard fails when UI code calls a performance-changing
# method on a Session, an Arrangement, or MB::Sound directly.
module CommandBusGuard
  # Methods that change a performance.
  MUTATORS = %i[
    add remove change go play swap capture rec record arm disarm turn move mute unmute solo unsolo stop bg
    launch seek skip forget panic undo redo! master feed learn snap recall xfade preview_turn
  ].freeze

  # Receivers that are the performance (source text of the receiver).
  PERFORMANCE = /\b(session|s|arrangement|MB::Sound|Session\.\w+)\b/

  # file:method => why it may change a Session itself.
  ALLOWED = {
    'lib/mb/sound/ui/warm_up.rb:add' => 'a private sandbox Session for YJIT warm-up, closed afterwards',
    'lib/mb/sound/ui/keyboard/link.rb:add' => "the keyboard's default patch, a live monitor for playing with nothing armed (not part of the performance; takes replay the MIDI it played through the MIDI log)",
    'lib/mb/sound/ui/keyboard/link.rb:remove' => 'rings out that monitor once a track is armed',
    'lib/mb/sound/ui/design.rb:track' => 'design is a console command (typed at the prompt: the take records its line); it makes the track as `track` would',
    'lib/mb/sound/ui/design.rb:bg' => 'design is a console command (typed at the prompt: the take records its line); it plays the track as `bg` would',
    'lib/mb/sound/ui/tiles.rb:preview_turn' => "a held key's live knob sweep (UI::TurnGesture): the Session records its steps and the gesture's one console line (Session#gesture_line) is journaled at its first step and replayed from there by takes",
  }.freeze
end

RSpec.describe('UI command bus guard') do
  include CommandBusGuard

  it 'finds no direct performance changes in UI code outside ALLOWED' do
    root = File.expand_path('../../../../..', __dir__)
    files = [File.join(root, 'lib/mb/sound/ui.rb'), *Dir.glob(File.join(root, 'lib/mb/sound/ui/**/*.rb'))]
    found = []
    files.each do |path|
      rel = path.delete_prefix("#{root}/")
      stack = [Prism.parse_file(path).value]
      until stack.empty?
        n = stack.pop
        next unless n
        reader = n.is_a?(Prism::CallNode) && n.name == :master && n.arguments.nil? && n.block.nil? # (a snapshot's master levels)
        if n.is_a?(Prism::CallNode) && n.receiver && CommandBusGuard::MUTATORS.include?(n.name) && !reader && n.receiver.slice.match?(CommandBusGuard::PERFORMANCE)
          key = "#{rel}:#{n.name}"
          found << "#{key} (line #{n.location.start_line}: #{n.slice.lines.first.strip})" unless CommandBusGuard::ALLOWED.key?(key)
        end
        stack.concat(n.compact_child_nodes)
      end
    end
    expect(found).to eq([]), "UI code changes the performance directly; run a console command through UI.run_line instead (or add to ALLOWED with a reason):\n#{found.join("\n")}"
  end
end

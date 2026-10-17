require 'fileutils'

module MB
  module Sound
    # `debug_dump` (ux-1 item 20): one command that writes what is needed
    # to diagnose a live problem to a folder, to read or send along.
    module DebugMethods
      # Writes the console's state to tmp/debug/<time>/ in mb-sound's folder
      # (or +dir+): now.txt (`now`), players.txt, changes.txt (the
      # journal), graphs/<player>.rb (each player's graph as Ruby, or why
      # not), ui.txt (`ui.list`: mode, layout, terminal size, panes; the
      # screen's stats, messages, and text), take.rb (the
      # take's replay script) and midi.txt (the last 500 MIDI events),
      # threads.txt (every thread's backtrace).  Each part that fails says
      # why in its file and the rest still write.  Returns the folder.
      def debug_dump(dir = nil)
        dir ||= File.join(File.expand_path('../../..', __dir__), 'tmp', 'debug', Time.now.strftime('%Y%m%d_%H%M%S'))
        FileUtils.mkdir_p(File.join(dir, 'graphs'))
        session = Session.existing
        part = lambda { |name, &block|
          text = begin
            block.call.to_s
          rescue StandardError, ScriptError => e
            "(failed: #{e.class}: #{e.message})\n#{e.backtrace&.first(8)&.join("\n")}"
          end
          File.write(File.join(dir, name), text.end_with?("\n") ? text : "#{text}\n")
        }

        part.('now.txt') { defined?(Help::Now) ? Help::Now.new.to_s.gsub(/\e\[[0-9;]*m/, '') : '(help not loaded: bin/sound.rb loads it)' }
        part.('players.txt') { session ? session.players.map { |n, d| "#{n.inspect}: #{d}" }.join("\n") : 'no session' }
        part.('changes.txt') { session ? session.journal.changes.map(&:to_s).join("\n") : 'no session' }
        if session
          session.debug_graphs.each do |name, graph|
            part.("graphs/#{name.to_s.gsub(/[^\w.-]/, '_')}.rb") do
              nodes = graph.respond_to?(:nodes) ? graph.nodes : [graph]
              nodes.each_with_index.map { |n, i| "# channel #{i + 1}\n#{DebugMethods.graph_ruby(n)}" }.join("\n")
            end
          end
        end
        part.('ui.txt') do
          s = UI.screen || UI.tiles
          # (ui.list first: mode, layout, terminal size, each pane's place)
          next "#{UI.list}\n\nno UI" unless s
          [UI.list.to_s, '', s.inspect, '', 'stats:', s.stats.pretty_inspect, 'messages:', UI.messages.recent(50).map { |e| "#{e.severity} ×#{e.count} #{e.text}" },
           '', 'screen:', (s.respond_to?(:to_text) ? s.to_text : '')].flatten.join("\n")
        end
        part.('take.rb') { Take.active ? Take.active.to_ruby : 'no take (bin/sound.rb keeps one)' }
        part.('midi.txt') do
          next 'no session' unless session
          n = session.midi_log_length
          session.midi_log([n - 500, 0].max).map { |name, epoch, pos, bytes| "#{epoch} #{Session::Stamp.at(pos, session.transport)} #{name.inspect} #{bytes.inspect}" }.join("\n")
        end
        part.('threads.txt') do
          Thread.list.map { |t| "#{t.name || t.inspect} (#{t.status})\n  #{(t.backtrace || []).first(30).join("\n  ")}" }.join("\n\n")
        end
        puts "Wrote #{dir}"
        dir
      end
    end

    module DebugMethods
      # The Ruby of the graph a player plays (the Session wraps the user's
      # graph in nodes of its own, whose recipes read `input`: the first
      # node inside with a recipe of its own), or its inspect.
      def self.graph_ruby(node)
        candidates = node.respond_to?(:graph) ? node.graph : [node]
        candidates.each do |n|
          next unless n.respond_to?(:to_ruby)
          text = n.to_ruby rescue next
          return text unless text.include?('# inputs: input')
        end
        node.inspect
      end
    end

    extend DebugMethods
  end
end

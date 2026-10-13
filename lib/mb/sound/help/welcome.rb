module MB
  module Sound
    module Help
      # The console's welcome screen (bin/sound.rb): a few lines on where
      # help is, then one random runnable tip (maintainer, 2026-10-13: "A
      # few more lines but yes").  Until there is a level check, a line
      # offers one.
      def self.welcome(random: Random.new)
        t = Text
        lines = []
        lines << "#{t.c(:title, 'Welcome to mb-sound,')} the interactive sound environment!"
        lines << "  #{t.code('help')} the one-screen sheet  #{t.code('help :knobs')} a topic  #{t.code('help /reverb/')} search  #{t.code('help.topics')}"
        lines << "  #{t.code('now')} what's playing  #{t.code('lesson')} guided lessons  #{t.code('bg :a, 220.hz.triangle.at(-20.db)')}, #{t.code('stop :a')}"
        unless Level.saved?
          lines << "  #{t.code('help.level')} #{t.c(:dim, 'sets a comfortable level for examples (the first try asks)')}"
        end
        lines << t.c(:dim, "  New to Ruby? https://www.ruby-lang.org/en/documentation/quickstart/  Pry's help: pry-help")
        lines << ''
        lines << Desk.new(index).tip(random: random).to_s
        lines.join("\n")
      end
    end
  end
end

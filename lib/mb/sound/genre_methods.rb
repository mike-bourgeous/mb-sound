module MB
  module Sound
    # Console methods for genre templates (see MB::Sound::Genre and
    # design/notes/genres.md).
    module GenreMethods
      # Returns the genre template +name+ (a Genre::Template: tempo, form,
      # drum kits, roles with suggested patches, scenes, mix targets, and
      # tips), changed by +changes+ (any Template field, as Data#with) and
      # the builder +block+ if given.  Without a name, lists the genres
      # (see #genres).
      #
      # Examples:
      #     genre :dnb                               # the summary; .to_ruby prints it all
      #     genre(:dnb).short.play                   # set it up and play its form, about a minute
      #     genre(:jungle).tips
      #     genre(:dnb, tempo: 172).setup; go :drop  # tracks and scenes to play by hand
      #     genre(:dnb) { tempo 170; role :bass, :jungle_reese, level: -2.db }
      def genre(name = nil, **changes, &block)
        return genres if name.nil?
        Genre[name].with(**changes, &block)
      end

      # Lists the genre templates (name, title, tempo) and returns their
      # names.
      def genres
        Genre.names.each do |n|
          t = Genre[n]
          puts format('  %-10s %-36s %s BPM (%s)', n.inspect, t.title, Genre.ruby(t.tempo), t.tempo_range)
        end
        Genre.names
      end
    end
  end
end

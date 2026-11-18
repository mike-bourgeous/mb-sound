module MB
  module Sound
    # The `demo` console command (ux-r3 item 26): a whole set to look
    # around in, loaded paused at bar 1 from a set document that ships in
    # mb-sound's presets/ (saved from a bin/songs/ script by
    # bin/save_presets.rb).  MB::Sound extends itself with this module.
    #
    #     demo                  # Night Bus: tracks, scenes, knobs, master, flow
    #     tracks; scenes        # what it holds
    #     go :drop              # a scene (the timeline starts)
    #     play_form demo.form   # or the whole flow (demo returns the document)
    #     demos                 # the sets there are
    module DemoMethods
      # The demo sets: name => what it is.
      DEMOS = {
        night_bus: '"Night Bus: Last Stop", tech house at 126 BPM in A minor (bin/songs/night_bus_flow.rb)',
        tunnel_vision: '"Tunnel Vision", drum & bass at 174 BPM in F minor with hall and echo buses (bin/songs/tunnel_vision.rb)',
      }.freeze

      # Loads demo set +name+ (see #demos) into the current Session, paused
      # at bar 1: tracks, scenes, knobs, the master chain, and its flow,
      # nothing playing.  Prints what to try.  Returns the set's
      # GraphIO::Document (`play_form doc.form`); `demo` again returns the
      # one loaded last without loading it again.
      #
      # A new demo replaces the whole set before it (the maintainer,
      # 2026-11-18: "A new demo should replace the entire previous demo"):
      # it stops everything and clears the set first (Session#clear_set),
      # saying what it replaced, all one undo step (undo puts the earlier
      # set back).  A demo that fails to load says so in one line
      # (#load_failure).
      def demo(name = nil)
        last = Session.current.arrangement.demo_document
        return last if name.nil? && last && !Session.current.arrangement.tracks.empty?
        name = (name || :night_bus).to_sym
        unless DEMOS.key?(name)
          return MB::Sound.live_error(ArgumentError.new("No demo #{name.inspect}#{GraphIO.suggest(name, DEMOS.keys)} (demos: #{DEMOS.keys.map(&:inspect).join(', ')})"))
        end

        s = Session.current
        replaced = s.set_summary
        path = File.join(GraphIO.library_presets_dir, "#{name}#{GraphIO::EXTENSION}")
        doc = begin
          s.clear_set(label: "demo #{name.inspect}") {
            rewind
            GraphIO.load(path, session: s).tap { |d| s.arrangement.demo_document = d }
          }
        rescue StandardError => e
          return MB::Sound.live_error(load_failure(name, e))
        end
        return nil if doc.nil? # (refused live: an armed or wired track)

        arr = s.arrangement
        puts "\e[1mdemo #{name.inspect}\e[0m: #{DEMOS[name]}, paused at bar 1"
        puts "  replaced #{replaced} (undo puts it back)" unless replaced.empty?
        puts "  tracks  #{arr.tracks.keys.join(' ')}"
        puts "  scenes  #{arr.scenes.keys.join(' ')}"
        puts "  knobs   #{s.knobs.keys.join(' ')}" unless s.knobs.empty?
        puts "\e[2mTry:\e[0m go :#{arr.scenes.keys[1] || arr.scenes.keys[0]}    turn :cut, 3000, over: 2    go :drop    stop :all"
        puts "\e[2m     \e[0mplay_form demo.form   (the whole song; loop!, onward, finish steer it)    ui :tiles    help :demo"
        doc
      end

      # The demo sets (name => what it is), printed as a list.
      def demos
        DEMOS.each { |n, about| puts "  #{n.inspect.ljust(14)} #{about}" }
        DEMOS
      end

      private

      # The error #demo reports when demo +name+ fails to load with +e+:
      # +e+ itself when it reads as one line (a GraphIO::LoadError, an
      # ArgumentError; see ErrorFormat.short?), else (a bug inside the
      # library) a GraphIO::LoadError of one line naming the error and
      # where it was raised, with +e+ as its cause (fixes-15: a
      # NoMethodError printed its whole backtrace in the console).
      def load_failure(name, e)
        return e if ErrorFormat.short?(e)

        frame = e.backtrace&.first.to_s[/\A[^:]+:\d+/]
        where = frame ? " at #{frame.delete_prefix("#{File.expand_path('../../..', __dir__)}/")}" : ''
        error = GraphIO::LoadError.new(
          "demo #{name.inspect} didn't load (the set may be partly there; undo puts back the set before it): #{ErrorFormat.summary(e)}#{where}, a bug in mb-sound"
        )
        error.set_backtrace(e.backtrace)
        error
      end
    end

    extend DemoMethods
  end
end

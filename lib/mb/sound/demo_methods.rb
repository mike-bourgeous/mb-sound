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
      }.freeze

      # Loads demo set +name+ (see #demos) into the current Session, paused
      # at bar 1: tracks, scenes, knobs, the master chain, and its flow,
      # nothing playing.  Prints what to try.  Returns the set's
      # GraphIO::Document (`play_form doc.form`); `demo` again returns the
      # one loaded last without loading it again.
      #
      # The Session must be quiet: with players playing, it says so (the
      # set's scenes would land on top of them) unless +replace: true+,
      # which stops everything first (as #panic, quietly).
      def demo(name = nil, replace: false)
        last = Session.current.arrangement.demo_document
        return last if name.nil? && last && !Session.current.arrangement.tracks.empty?
        name = (name || :night_bus).to_sym
        unless DEMOS.key?(name)
          return MB::Sound.live_error(ArgumentError.new("No demo #{name.inspect}#{GraphIO.suggest(name, DEMOS.keys)} (demos: #{DEMOS.keys.map(&:inspect).join(', ')})"))
        end

        s = Session.current
        unless s.players.empty?
          unless replace
            return MB::Sound.live_error(ArgumentError.new(
              "demo #{name.inspect} loads into this Session, but #{s.players.keys.map(&:inspect).join(', ')} #{s.players.length == 1 ? 'is' : 'are'} playing " \
              "(stop :all, fade: 0 first, or demo #{name.inspect}, replace: true)"
            ))
          end
          s.reset_scheduler
          s.remove(fade: 0)
          s.process_buffer unless s.realtime?
        end

        path = File.join(GraphIO.library_presets_dir, "#{name}#{GraphIO::EXTENSION}")
        doc = GraphIO.load(path, session: s)
        rewind if s.players.empty?
        s.arrangement.demo_document = doc

        arr = s.arrangement
        puts "\e[1mdemo #{name.inspect}\e[0m: #{DEMOS[name]}, paused at bar 1"
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
    end

    extend DemoMethods
  end
end

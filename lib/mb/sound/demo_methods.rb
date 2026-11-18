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
      # The Session must be quiet: with players playing, it says so (the
      # set's scenes would land on top of them) unless +replace: true+,
      # which stops everything first (as #panic, quietly).  A demo that
      # fails to load says so in one line (#load_failure).
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
        begin
          doc = GraphIO.load(path, session: s)
        rescue StandardError => e
          return MB::Sound.live_error(load_failure(name, e))
        end
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

      private

      # The name of the demo set +session+ holds (see #demo), or nil.
      def loaded_demo(session)
        path = session.arrangement.demo_document&.path
        path && File.basename(path, GraphIO::EXTENSION).to_sym
      end

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
          "demo #{name.inspect} didn't load (the set may be partly there): #{ErrorFormat.summary(e)}#{where}, a bug in mb-sound"
        )
        error.set_backtrace(e.backtrace)
        error
      end
    end

    extend DemoMethods
  end
end

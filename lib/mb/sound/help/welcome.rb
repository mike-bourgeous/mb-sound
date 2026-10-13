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
        if Level.saved?
          trim = 20 * Math.log10([Session.monitor_gain, 1e-9].max)
          lines << "  #{t.c(:dim, format('monitor trim %+.0f dB (help.level)', trim))}" if trim.abs >= 0.05
        else
          lines << "  #{t.code('help.level')} #{t.c(:dim, 'sets a comfortable listening level (a monitor trim; renders unchanged)')}"
        end
        lines << t.c(:dim, "  New to Ruby? https://www.ruby-lang.org/en/documentation/quickstart/  Pry's help: pry-help")
        lines << ''
        lines << Desk.new(index).tip(random: random).to_s
        lines.join("\n")
      end

      # Runs the level check before the console's first prompt, the first
      # time only (maintainer, 2026-10-13: "Before starting Pry even?"):
      # when there is no saved level, +input+ is a terminal, and the output
      # is a real one (not OUTPUT_TYPE=null or ffmpeg).  Enter keeps the
      # default right away.  MB_SOUND_LEVEL_CHECK=0 skips it.  Returns the
      # chosen level, or nil if it didn't run or was cancelled.
      def self.first_level_check(input: $stdin, out: $stdout, output_type: MB::Sound.detect_output, player: nil)
        return nil if Level.saved? || ENV['MB_SOUND_LEVEL_CHECK'] == '0'
        return nil unless input.respond_to?(:tty?) && input.tty?
        return nil unless output_type == :device

        out.puts Text.c(:dim, 'First launch: a quick level check (Enter keeps the default; help.level runs it again).')
        Level::Calibration.new(input: input, out: out, player: player || Level::SessionPlayer.new).run
      rescue StandardError => e
        out.puts Text.c(:warn, "Level check skipped (#{e.class}: #{e.message}); help.level runs it later")
        nil
      end
    end
  end
end

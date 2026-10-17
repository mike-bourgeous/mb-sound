module MB
  module Sound
    module Help
      # The welcome screen's commands, grouped (ux-1 r3 item 1; maintainer:
      # "too condensed without visual affordances"): one command per line,
      # descriptions aligned and dim, through the same formatter as the
      # sheet's footer (Doc#commands).
      WELCOME = [
        ['Learn', [
          ['lesson', 'guided lessons'],
          ['help.tip', 'a random example to play'],
        ]],
        ['Play', [
          ['bg :a, 220.hz.triangle.at(-20.db)', 'a sound in the background'],
          ['stop :a', 'stops it'],
          ['now', "what's playing and what you can do"],
        ]],
        ['Help', [
          ['help', 'the one-screen sheet'],
          ['help :knobs', 'a topic (help.topics lists them)'],
          ['help /reverb/', 'search names, topics, and docs'],
        ]],
      ].freeze

      # The console's welcome screen (bin/sound.rb): the commands to start
      # with (WELCOME), a footer set apart (the monitor trim or the level
      # check, Ruby and Pry links), then one random runnable tip
      # (maintainer, 2026-10-13: "A few more lines but yes").  Plain under
      # NO_COLOR or when +io+ isn't a terminal.
      def self.welcome(random: Random.new, io: $stdout)
        t = Text
        doc = Doc.new
        doc.lines(["#{t.c(:title, 'Welcome to mb-sound,')} the interactive sound environment!"])
        doc.commands(WELCOME)
        foot = []
        if Level.saved?
          trim = 20 * Math.log10([Session.monitor_gain, 1e-9].max)
          foot << t.c(:dim, format('monitor trim %+.0f dB (help.level)', trim)) if trim.abs >= 0.05
        else
          foot << "#{t.code('help.level')} #{t.c(:dim, 'sets a comfortable listening level (a monitor trim; renders unchanged)')}"
        end
        foot << t.c(:dim, 'New to Ruby? https://www.ruby-lang.org/en/documentation/quickstart/')
        foot << t.c(:dim, "Pry's own help: pry-help")
        doc.lines(foot)
        doc.lines([Desk.new(index).tip(random: random).to_s])
        Help.for_output(doc.to_s, io)
      end

      # Runs the level check before the console's first prompt, the first
      # time only (maintainer, 2026-10-13: "Before starting Pry even?"):
      # when there is no saved level, +input+ is a terminal, and the output
      # is a real one (not OUTPUT_TYPE=null or ffmpeg).  Enter keeps the
      # default right away.  MB_SOUND_LEVEL_CHECK=0 skips it.  Returns the
      # chosen level, or nil if it didn't run or was cancelled.
      def self.first_level_check(input: $stdin, out: $stdout, output_type: MB::Sound::Internal.detect_output, player: nil)
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

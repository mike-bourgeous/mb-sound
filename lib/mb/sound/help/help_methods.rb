module MB
  module Sound
    # Console help (see MB::Sound::Help and design/notes/help.md): the
    # one-screen sheet, topic and method pages generated from doc comments,
    # what is playing now, and lessons.  bin/sound.rb loads it (it is not
    # part of `require 'mb/sound'`; in other scripts the first #help, #now,
    # or #lesson loads it, see HelpAutoload); MB::Sound then extends itself
    # with this module.
    #
    # Example (bin/sound.rb):
    #     help                # the one-screen sheet
    #     help :knobs         # a topic (or help.knobs); help.topics lists them
    #     help(:knobs).try    # play its first example for a couple of bars
    #     help :turn          # one method: signature, aliases, doc comment
    #     help /reson/        # search names and doc comments
    #     help node           # explain a graph
    #     help.tip            # a random example to try
    #     help.level          # the listening level (sets the monitor trim)
    #     now                 # what's playing, and commands that apply
    #     lesson :set         # a lesson (lesson alone lists them)
    module HelpMethods
      # Help on anything: nothing for the one-screen sheet, a topic or
      # method name (Symbol or String), a Regexp to search names and doc
      # comments, or a graph to explain.  Returns a page that prints itself;
      # topic pages can play their examples (`help(:knobs).try`).  Pry's
      # own help command is `pry-help` in bin/sound.rb.
      def help(subject = nil)
        Help.page_for(subject)
      end

      # What's playing now (players, knobs, scenes, the form, queued and
      # recent changes), with the commands that apply, filled in with your
      # own names.  A one-shot printout (a live panel waits for the terminal
      # UI).
      def now
        Help::Now.new
      end

      # Lessons: with a name, starts or resumes one (+restart: true+ from
      # its first step); without, the lesson being taken (the list once it
      # is done).  A
      # lesson moves on when its step's check passes after a console line;
      # `lesson.run` types the step for you, `lesson.next`, `lesson.back`,
      # `lesson.hint`, `lesson.quit`.
      def lesson(name = nil, restart: false)
        if name
          l = Help::LESSONS.fetch(name.to_sym) {
            raise ArgumentError, "No lesson #{name.inspect} (#{Help::LESSONS.keys.map(&:inspect).join(', ')})"
          }
          if (why = l.busy)
            return MB::Sound.live_error(RuntimeError.new(why))
          end
          Help::LessonRunner.active = Help::LessonRunner.new(l, restart ? 0 : nil)
        else
          runner = Help::LessonRunner.active
          Help::LessonRunner.active = runner = nil if runner&.done?
          runner || Help::LessonList.new
        end
      end
    end
  end
end

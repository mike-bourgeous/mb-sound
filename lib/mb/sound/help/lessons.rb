require 'json'
require 'fileutils'

module MB
  module Sound
    module Help
      # Lessons (`lesson :set`).  A lesson is a list of steps; each step says
      # something, shows code to type, and checks the Session afterwards
      # (a Pry after_eval hook runs the check after every line, so typing the
      # code, or anything else that does the job, moves the lesson on).
      # Progress is saved, so `lesson :set` resumes where it stopped.
      class Lesson
        # One step.  +start+ (optional) runs when the step begins and its
        # result goes to +check+, so a check can look for something new
        # since then (e.g. a second capture).
        Step = Struct.new(:title, :text, :code, :check_text, :check, :hint, :start, :memo, keyword_init: true) do
          def source = code ? Text.block_body(code) : nil

          def begin!
            self.memo = start && MB::Sound.instance_exec(&start)
            self
          end

          def passed? = check.nil? || !!MB::Sound.instance_exec(memo, &check)
        end

        attr_reader :name, :title, :minutes, :about, :steps, :needs

        def initialize(name, title, minutes)
          @name, @title, @minutes = name, title, minutes
          @about = +''
          @steps = []
          @needs = []
        end

        # Lesson builder: `step 'title' do ... end`.
        class Builder
          def initialize(lesson) = @lesson = lesson
          def about(text) = @lesson.about.replace(text.gsub(/\s+/, ' ').strip)

          # What the lesson needs besides a sound card (:midi, a keyboard;
          # the guard spec plays a stand-in keyboard).
          def needs(*things) = @lesson.needs.concat(things)

          def step(title, &block)
            step = Step.new(title: title)
            StepBuilder.new(step).instance_eval(&block)
            @lesson.steps << step
          end
        end

        # Step builder: say, type (the code, as a block never run here), and
        # check (a block run in MB::Sound after each line typed).
        class StepBuilder
          def initialize(step) = @step = step
          def say(text) = @step.text = text.gsub(/\s+/, ' ').strip
          def type(&block) = @step.code = block
          def hint(text) = @step.hint = text

          def check(description = nil, &block)
            @step.check_text = description
            @step.check = block
          end

          # Runs when the step begins; its result is the check's argument.
          def start(&block) = @step.start = block
        end
      end

      LESSONS = {}

      def self.lesson(name, title, minutes: 5, &block)
        l = Lesson.new(name, title, minutes)
        Lesson::Builder.new(l).instance_eval(&block)
        LESSONS[name] = l
      end

      # Saved progress: lesson name => next step index.
      module Progress
        module_function

        def dir = Help.data_dir

        def path = File.join(dir, 'progress.json')

        def load
          JSON.parse(File.read(path)).transform_keys(&:to_sym)
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end

        def save(name, step)
          data = load.merge(name => step)
          FileUtils.mkdir_p(dir)
          File.write(path, JSON.pretty_generate(data))
        end
      end

      # The lesson being taken: `lesson` shows the step, `lesson.next`,
      # `lesson.back`, `lesson.hint`, `lesson.run` (types the code for you),
      # `lesson.quit`.
      class LessonRunner
        include Page
        include Text

        class << self
          attr_accessor :active
        end

        attr_reader :lesson, :index

        def initialize(lesson, index = nil)
          @lesson = lesson
          @index = (index || Progress.load[lesson.name] || 0).clamp(0, lesson.steps.length)
          step&.begin!
        end

        def step = @lesson.steps[@index]
        def done? = @index >= @lesson.steps.length

        # Called after each console line: moves on when the step's check
        # passes; returns the text to print (or nil).
        def after_line
          return nil if done? || step.check.nil?
          return nil unless (step.passed? rescue false)

          msg = c(:ok, "✓ #{step.check_text || step.title}")
          advance
          "#{msg}\n\n#{self}"
        end

        def next
          advance
          self
        end

        def back
          @index = [@index - 1, 0].max
          Progress.save(@lesson.name, @index)
          step&.begin!
          self
        end

        def hint = step&.hint || 'Type the code above (or `lesson.run` to have it typed for you).'

        # Runs the step's code as if typed (at the listening level, see
        # Help::Level), then checks it.
        def run
          return self if done? || step.code.nil?
          puts step.source.lines.map { |l| code(l.chomp) }.join("\n")
          Try::Context.new(Level.try_gain).instance_exec(&step.code)
          msg = after_line
          puts msg.lines.first if msg
          self
        end

        def quit
          LessonRunner.active = nil
          puts c(:dim, "left #{@lesson.name} at step #{@index + 1} (lesson #{@lesson.name.inspect} resumes it)")
          LessonList.new
        end

        def to_s
          n = @lesson.steps.length
          if done?
            return "#{c(:title, @lesson.title)} #{c(:ok, 'done!')}  #{c(:dim, "#{n} steps; `lesson` lists the others")}"
          end
          s = step
          out = []
          out << "#{c(:title, @lesson.title)}  #{progress_bar(@index, n)} #{c(:dim, "step #{@index + 1}/#{n}")}"
          out << c(:head, s.title)
          out << wrap(s.text.to_s, indent: 2).then { |t| doc(t) } if s.text
          if s.source
            out << ''
            out << s.source.lines.map { |l| "    #{code(l.chomp)}" }.join("\n")
          end
          out << ''
          out << c(:dim, "  waiting for: #{s.check_text}") if s.check_text
          out << c(:dim, '  lesson.run types it for you; lesson.hint, lesson.next, lesson.back, lesson.quit')
          out.join("\n")
        end

        private

        def advance
          @index += 1
          Progress.save(@lesson.name, @index)
          step&.begin!
        end

        def progress_bar(i, n) = c(:bar, '●' * i + '○' * (n - i))
      end

      # `lesson` with no argument: the active lesson, or the list.
      class LessonList
        include Page
        include Text

        def to_s
          prog = Progress.load
          out = [c(:title, 'lessons') + c(:dim, '  lesson :name starts or resumes one')]
          LESSONS.each_value do |l|
            done = prog[l.name].to_i
            state = done >= l.steps.length ? c(:ok, 'done') : (done > 0 ? "step #{done + 1}/#{l.steps.length}" : "#{l.steps.length} steps")
            out << "  #{pad(c(:key, l.name.inspect), 12)} #{pad(l.title, 34)} #{c(:dim, "~#{l.minutes} min")}  #{state}"
            out << "  #{' ' * 12} #{c(:dim, l.about[0, width - 16])}" unless l.about.empty?
          end
          out.join("\n")
        end
      end
    end
  end
end

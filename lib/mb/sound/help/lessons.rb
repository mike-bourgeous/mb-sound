require 'json'
require 'fileutils'

module MB
  module Sound
    module Help
      # Lessons (`lesson :set`).  A lesson is a list of steps; each step says
      # something, shows code to type, and checks the Session afterwards
      # (a Pry after_eval hook runs the check after every line, so typing the
      # code, or anything else that does the job, moves the lesson on).
      #
      # A lesson builds state in the Session (tracks, clips, knobs) that a
      # new console doesn't have (ux-r3 item 34), so a run (LessonRunner:
      # lesson, step, Session) lives only in this console: `lesson :set`
      # resumes this console's run, or starts at step 1.  Completion is kept
      # apart (History, in Help.data_dir), shown as a check mark in the
      # list; `lesson :set, from: 4` replays steps 1-3's code first so the
      # state exists.
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

        # Why the lesson can't start now (a String), or nil: a lesson that
        # launches its own scenes and form (needs :idle_set) would take
        # over a form or scene of yours that is playing (the jungle
        # persona's song lost its scenes to `lesson :flow`, 2026-10-13).
        def busy
          return nil unless @needs.include?(:idle_set)

          set = Session.current.arrangement
          pb = set.playback
          if pb && !pb.ended?
            "lesson #{@name.inspect} plays its own form, which would take over the form playing now; `finish` (or `stop :all`) first"
          elsif (scene = set.current_scene) && !scene.to_s.start_with?('l_') &&
                (mine = set.tracks.keys.reject { |t| t.to_s.start_with?('l_') }.select { |t| Session.current.playing_after_queue?(t) }).any?
            "lesson #{@name.inspect} launches its own scenes, which would stop #{mine.map(&:inspect).join(', ')} (scene #{scene.inspect}); `stop :all` first"
          end
        end

        # Lesson builder: `step 'title' do ... end`.
        class Builder
          def initialize(lesson) = @lesson = lesson
          def about(text) = @lesson.about.replace(text.gsub(/\s+/, ' ').strip)

          # What the lesson needs besides a sound card (:midi, a keyboard;
          # the guard spec plays a stand-in keyboard; :idle_set, no form or
          # scene playing, for lessons that launch their own; see
          # Lesson#busy).
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

      # The lessons whose steps type a call to one of +names+, as [lesson
      # name, step number (from 1), steps] (the first such step of each),
      # for method pages' "Learn it in" (ux-1 item 26).
      def self.lessons_using(names)
        names = names.map(&:to_sym)
        LESSONS.each_value.filter_map do |l|
          i = l.steps.index { |st| st.code && (Lesson.call_names(st.source) & names).any? }
          [l.name, i + 1, l.steps.length] if i
        end
      end

      class Lesson
        # Method names called in +source+ (Prism).
        def self.call_names(source)
          @call_names ||= {}
          @call_names[source] ||= begin
            names = []
            walk = ->(n) {
              next if n.nil?
              names << n.name if n.is_a?(Prism::CallNode)
              n.compact_child_nodes.each { |c| walk.(c) }
            }
            walk.(Prism.parse(source.to_s).value)
            names.uniq.freeze
          end
        end
      end

      def self.lesson(name, title, minutes: 5, &block)
        l = Lesson.new(name, title, minutes)
        Lesson::Builder.new(l).instance_eval(&block)
        LESSONS[name] = l
      end

      # Lessons finished, kept across consoles (Help.data_dir/progress.json):
      # name => { "completed" => time }.  Files from before ux-r3 held name
      # => next step index; an index past the last step counts as finished.
      module History
        module_function

        def dir = Help.data_dir

        def path = File.join(dir, 'progress.json')

        def load
          JSON.parse(File.read(path)).transform_keys(&:to_sym)
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end

        # True if +lesson+ (a Lesson) was finished in any console.
        def completed?(lesson)
          v = load[lesson.name]
          v.is_a?(Hash) ? !v['completed'].nil? : v.is_a?(Integer) && v >= lesson.steps.length
        end

        # Records that lesson +name+ was finished.
        def complete(name)
          data = load.merge(name.to_sym => { 'completed' => Time.now.utc.iso8601 })
          FileUtils.mkdir_p(dir)
          File.write(path, JSON.pretty_generate(data))
        end
      end

      # A lesson being taken in this console: `lesson` shows the step,
      # `lesson.next`, `lesson.back`, `lesson.hint`, `lesson.run` (types the
      # code for you), `lesson.quit`.
      #
      # A run is an explicit state machine (STATES, EVENTS, TABLE): it is
      # :running (lesson shows it, lines are checked), :left (`lesson.quit`;
      # `lesson :x` resumes it in this console), or :done (past its last
      # step; History records it).  Runs belong to the Session they started
      # in: in another Session (or a new console) the lesson starts over.
      class LessonRunner
        include Page
        include Text

        # Run states.
        STATES = %i[running left done].freeze

        # Run events (:advance moves to the next step, :finish past the
        # last one).
        EVENTS = %i[advance finish back restart quit resume].freeze

        # Every (state, event) pair's next state.
        TABLE = {
          running: { advance: :running, finish: :done, back: :running, restart: :running, quit: :left, resume: :running },
          left: { advance: :left, finish: :left, back: :left, restart: :running, quit: :left, resume: :running },
          done: { advance: :done, finish: :done, back: :running, restart: :running, quit: :done, resume: :done },
        }.transform_values(&:freeze).freeze

        class << self
          # The run `lesson` shows and console lines check, or nil.
          attr_accessor :active

          # This console's runs: lesson name => LessonRunner.
          def runs
            @runs ||= {}
          end

          # The state +state+ goes to on +event+.
          def next_state(state, event)
            TABLE.fetch(state) { raise ArgumentError, "Unknown lesson state #{state.inspect}" }
              .fetch(event) { raise ArgumentError, "Unknown lesson event #{event.inspect}" }
          end

          # The run of +lesson+ to show for `lesson :name` (+from+: a step
          # number to start at, replaying the steps before it; +restart+:
          # step 1): this console's run in the current Session if it isn't
          # done, else a new one.
          def for(lesson, from: nil, restart: false)
            session = Session.current
            old = runs[lesson.name]
            if from.nil? && !restart && old && old.state != :done && old.session.equal?(session)
              old.fire(:resume)
              return old
            end

            run = new(lesson, 0)
            runs[lesson.name] = run
            run.replay_to(from - 1) if from && from > 1
            run
          end
        end

        attr_reader :lesson, :index, :state, :session

        def initialize(lesson, index = nil)
          @lesson = lesson
          @index = (index || 0).clamp(0, lesson.steps.length)
          @revisit = nil
          @session = Session.current
          @state = done? ? :done : :running
          step&.begin!
        end

        # Applies +event+ (see TABLE).  Returns self.
        def fire(event)
          @state = LessonRunner.next_state(@state, event)
          History.complete(@lesson.name) if @state == :done && event == :finish
          self
        end

        def step = @lesson.steps[@index]
        def done? = @index >= @lesson.steps.length

        # Runs the code of the steps before step index +n+ (0-based), so a
        # run started part way (`lesson :set, from: 4`) has the state they
        # build, printing each step's title.  Returns self.
        def replay_to(n)
          n = n.clamp(0, @lesson.steps.length)
          while @index < n
            s = step
            puts c(:dim, "replaying step #{@index + 1}: #{s.title}")
            MB::Sound.instance_exec(&s.code) if s.code
            advance
          end
          self
        end

        # Where files the lesson's code makes without a path go while the
        # lesson runs (e.g. `rec_audio` alone; see
        # RecordMethods#rec_audio): a folder for the lesson in the help
        # directory (Help.data_dir), so lessons never write next to the
        # performer's own takes.  Nil once the lesson is done.
        def files_dir = done? ? nil : File.join(Help.data_dir, 'lessons', @lesson.name.to_s)

        # Called after each console line: moves on when the step's check
        # passes; returns the text to print (or nil).
        def after_line
          return nil if done? || step.check.nil? || @state != :running
          # A step gone back to (lesson.back) whose check already passes
          # waits for lesson.next or lesson.run instead of moving on at
          # once (the line that went back would otherwise undo it)
          return nil if @revisit == @index
          return nil unless (step.passed? rescue false)

          msg = c(:ok, "✓ #{step.check_text || step.title}")
          advance
          "\n#{msg}\n#{self}"
        end

        def next
          advance
          self
        end

        def back
          @index = [@index - 1, 0].max
          fire(:back)
          step&.begin!
          @revisit = @index
          self
        end

        def hint = step&.hint || 'Type the code above (or `lesson.run` to have it typed for you).'

        # Runs the step's code as if typed, then checks it.
        def run
          return self if done? || step.code.nil?
          puts step.source.lines.map { |l| code(l.chomp) }.join("\n")
          MB::Sound.instance_exec(&step.code)
          @revisit = nil
          msg = after_line
          puts msg.lines.first if msg
          self
        end

        def quit
          fire(:quit)
          LessonRunner.active = nil
          puts c(:dim, "left #{@lesson.name} at step #{@index + 1} (lesson #{@lesson.name.inspect} resumes it in this console)")
          LessonList.new
        end

        # The step as a page: a blank line above and below (lesson
        # messages print between console lines; ux-1 item 27), a dim
        # "lesson :set · step 2/5" line, the step's title and text, the
        # code to type, and the check in color.
        def to_s
          n = @lesson.steps.length
          d = Doc.new
          if done?
            d.lines(["#{c(:dim, "lesson #{@lesson.name.inspect} · done")}  #{c(:title, @lesson.title)} #{c(:ok, 'done!')}  #{c(:dim, "#{n} steps; `lesson` lists the others")}"])
            return "\n#{d}\n"
          end
          s = step
          d.lines([
            "#{c(:dim, "lesson #{@lesson.name.inspect} · step #{@index + 1}/#{n}")}  #{progress_bar(@index, n)}",
            "#{c(:title, @lesson.title)}: #{c(:head, s.title)}",
          ])
          d.para(s.text.to_s, indent: 2) if s.text
          d.code_block(s.source) if s.source
          check =
            if @revisit == @index && (s.passed? rescue false)
              c(:ok, '  ✓ already done; lesson.next moves on, lesson.run does it again')
            elsif s.check_text
              "  #{c(:warn, '…')} #{c(:bar, "waiting for: #{s.check_text}")}"
            end
          d.lines([check, c(:dim, '  lesson.run types it for you; lesson.hint, lesson.next, lesson.back, lesson.quit')].compact)
          "\n#{d}\n"
        end

        private

        def advance
          @revisit = nil
          @index += 1
          fire(done? ? :finish : :advance)
          step&.begin!
        end

        def progress_bar(i, n) = c(:bar, '●' * i + '○' * (n - i))
      end

      # `lesson` with no argument: the active lesson, or the list.
      class LessonList
        include Page
        include Text

        def to_s
          out = [c(:title, 'lessons') + c(:dim, '  lesson :name starts one (or resumes it in this console); from: 3 starts at step 3')]
          LESSONS.each_value do |l|
            run = LessonRunner.runs[l.name]
            run = nil unless run&.session.equal?(Session.existing)
            before = History.completed?(l) ? c(:ok, ' ✓ done before') : ''
            state =
              if run&.state == :done then c(:ok, 'done')
              elsif run then "step #{run.index + 1}/#{l.steps.length}#{run.state == :left ? ' (left)' : ''}#{before}"
              else "#{l.steps.length} steps#{before}"
              end
            out << "  #{pad(c(:key, l.name.inspect), 12)} #{pad(l.title, 34)} #{c(:dim, "~#{l.minutes} min")}  #{state}"
            out << "  #{' ' * 12} #{c(:dim, l.about[0, width - 16])}" unless l.about.empty?
          end
          out.join("\n")
        end
      end
    end
  end
end

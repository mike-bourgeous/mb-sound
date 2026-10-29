module MB
  module Sound
    class Form
      # A form's passes worked out ahead without playing anything (G4): the
      # decisions Playback would make at each commit point with no
      # performer controls (picks, weighted gotos, goto Procs, and generate
      # steps drawn the same way), so the pass playing at any position can
      # be found cold: a seek into a long generated piece plays what an
      # uninterrupted run plays there.  Steered sources read their params'
      # values at the simulated commit points (peeks: nothing is decided or
      # logged).  Passes are computed lazily and kept.
      #
      #     plan = form.plan(seed: 3)
      #     plan.first(4).map(&:section)      # => [:still, :drift, :drift, :bloom]
      #     plan.at(400)                      # the pass playing at whole note 400
      #
      # Sections whose scenes change the meter as they launch are counted in
      # the meter the transport has when the plan is made.
      class Plan
        include Enumerable
        include Walking

        # One pass: its instruction +index+, +section+, +pass+ number,
        # +length+ (a Duration or bars), +times+, where it starts and ends
        # (whole notes), the counters adopted when it starts, and how many
        # passes played before it (+number+, from 0).
        Pass = Data.define(:index, :section, :pass, :length, :times, :start, :stop, :counters, :number)

        # The most passes #at walks before giving up.
        LIMIT = 1_000_000

        # The section names of the passes computed so far (frozen copy).
        def history
          @history.dup.freeze
        end

        # +transport+ counts bar lengths (a new 4/4 one by default, or one
        # with +bar_length+); +start+ is where the form starts (whole notes).
        def initialize(form, seed:, transport: nil, bar_length: nil, start: 0)
          @form = form
          @program = form.program
          @seed = Integer(seed)
          @transport = transport || Sequence::Transport.new(bpm: 120).tap { |t| t.bar_length = bar_length if bar_length }
          @start_time = start.to_r
          @counters = {}.freeze
          @history = []
          @passes = []
          @next = nil
          @done = false
          @section = nil
          @pass = nil
          @boundary = nil
          @lock = Mutex.new
        end

        # Yields every pass in order (forever for endless forms: use #first,
        # #take, #lazy, or #at).
        def each
          return enum_for(:each) unless block_given?
          k = 0
          while (p = self[k])
            yield p
            k += 1
          end
          self
        end

        # Pass +k+ (from 0), or nil past the form's end.
        def [](k)
          @lock.synchronize {
            compute while @passes.length <= k && !@done
            @passes[k]
          }
        end

        # The pass playing at timeline position +pos+ (whole notes), or nil
        # before the start or after the end.
        def at(pos)
          pos = pos.to_r
          return nil if pos < @start_time
          k = 0
          LIMIT.times do
            p = self[k] or return nil
            return p if pos < p.stop
            k += 1
          end
          raise ArgumentError, "form plan: position #{pos} is more than #{LIMIT} passes in"
        end

        # The first pass at or after pass +from+ that plays section +name+,
        # within +limit+ passes, or nil.
        def find(name, from: 0, limit: 10_000)
          (from...(from + limit)).each do |k|
            p = self[k] or return nil
            return p if p.section == name
          end
          nil
        end

        def inspect
          "#<Form::Plan #{@passes.length} passes computed#{@done ? ', ended' : ''}>"
        end

        private

        # The next pass: Playback's begin_pass, commit, and cross, without
        # a Session.
        def compute
          step = if @passes.empty?
                   MIDI::Param.peek { walk(0, time: @start_time) }
                 else
                   last = @passes.last
                   sec = @form.sections[last.section]
                   fill_start = sec.fill ? [last.start, last.stop - length_before(sec.fill.length, last.stop)].max : nil
                   decide(last, fill_start || last.stop)
                 end
          if step.nil? || step.section.nil?
            @done = true
            return
          end

          start = @passes.empty? ? @start_time : @passes.last.stop
          @counters = step.counters
          @section = step.section
          @pass = step.pass
          @history << step.section
          stop = start + length_from(step.length, start)
          @boundary = stop
          @passes << Pass.new(index: step.index, section: step.section, pass: step.pass, length: step.length, times: step.times,
                              start: start, stop: stop, counters: step.counters, number: @passes.length)
        end

        # What follows +last+, decided at +time+.
        def decide(last, time)
          if last.pass < last.times
            return Step.new(index: last.index, section: last.section, pass: last.pass + 1, counters: @counters, labels: [].freeze,
                            length: last.length, times: last.times)
          end
          next_i = @program[last.index][0] == :generate ? last.index : last.index + 1
          MIDI::Param.peek { walk(next_i, time: time) }
        end

        def state_unlocked
          State.new(section: @section, pass: @pass, history: @history,
                    bars: @boundary ? @transport.bar_at(@boundary) - @transport.bar_at(@start_time) : 0)
        end
      end

      # The form's passes worked out ahead with +seed+ (see Plan).
      def plan(seed:, transport: nil, bar_length: nil, start: 0)
        Plan.new(self, seed: seed, transport: transport, bar_length: bar_length, start: start)
      end
    end
  end
end

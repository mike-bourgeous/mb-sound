module MB
  module Sound
    class Form
      # What a form has played so far, given to goto Procs (`goto ->(f) {
      # f.plays(:drop) < 2 ? :top : nil }`: back to label :top until the
      # drop has played twice, then carry on).  Read only: a snapshot made
      # when the flow decides what comes next (at the commit point of the
      # section before the goto).
      class State
        # The section playing now (a Symbol; nil before the first).
        attr_reader :section

        # The pass of the section playing now, counting from 1 (a section
        # with times: 2 plays passes 1 and 2; loop! adds more).
        attr_reader :pass

        # The sections played so far, one name per pass, oldest first
        # (frozen).
        attr_reader :history

        # Bars played since the form started (at the end of this pass).
        attr_reader :bars

        def initialize(section:, pass:, history:, bars:)
          @section = section
          @pass = pass
          @history = history.dup.freeze
          @bars = bars
          freeze
        end

        # How many passes of section +name+ have played (including the one
        # playing now).
        def plays(name)
          @history.count(name)
        end

        # The section played before the current run of this section (nil at
        # the start).
        def previous
          @history.reverse.find { |n| n != @section }
        end

        def to_s
          bars = @bars.respond_to?(:denominator) && @bars.denominator == 1 ? @bars.to_i : @bars
          "#{@section} pass #{@pass}, #{bars} bars in (#{@history.join(' ')})"
        end

        def inspect
          "#<Form::State #{self}>"
        end
      end
    end
  end
end

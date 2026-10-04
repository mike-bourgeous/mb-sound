module MB
  module Sound
    class Notes
      # Rises linearly from 0 to 1 over +delay+ seconds (a number or a node,
      # read where each fade starts) after every note-on, then stays at 1:
      # the fade-in of a delayed vibrato (see NotePitch#vibrato).  It is 1
      # before the first note and whenever the delay is 0.
      class FadeIn < Node::Held
        def initialize(stream, delay:, notes: nil, sample_rate: 48000)
          super(stream, notes: notes, sample_rate: sample_rate)
          @delay = delay.respond_to?(:sample) ? delay.get_sampler : delay.to_f
          @position = nil
          @length = 0
          @node_type_name = 'Notes Fade In'
        end

        def sample(count)
          if @delay.is_a?(Numeric)
            @delay_buf = nil
          else
            @delay_buf = @delay.sample(count.round)
            return nil if @delay_buf.nil?
          end
          super
        end

        def sources
          { stream: @stream, delay: @delay }
        end

        private

        def render(buf, items)
          @segment_start = 0
          super
        end

        def handle(event)
          return unless event.note_on?
          @position = 0
          seconds = @delay_buf ? @delay_buf[MB::M.min(@segment_start, @delay_buf.length - 1)] : @delay
          @length = (seconds * @sample_rate).round
        end

        def fill(buf, from, to)
          @segment_start = to
          if @position.nil? || @length <= 0 || @position >= @length
            buf[from...to] = 1.0
            return
          end

          n = to - from
          ramp = Numo::SFloat.new(n).seq(@position + 1) / @length
          buf[from...to] = ramp.clip(0.0, 1.0)
          @position += n
        end
      end
    end
  end
end

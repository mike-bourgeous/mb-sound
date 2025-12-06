module MB
  module Sound
    # Returns 
    def midi
      @mididsl ||= MB::Sound::GraphNode::MidiDsl.new
    end

    module GraphNode
      class MidiDsl
        def channel(ch)
          @channels ||= []
          @channels[ch] ||= MidiDsl.new(channel: ch)
        end

        def cc(number, use_lsb: false)
          MidiConstant.new(mode: :cc) # ...
        end

        def hz
          MidiConstant.new(mode: :note) # ...
        end

        def number
          MidiConstant.new(mode: :number) # ...
        end

        def velocity(number = nil)
          MidiConstant.new(mode: :velocity, ref: number)
        end

        def bend
          MidiConstant.new(mode: :bend) # ...
        end
      end
    end
  end
end

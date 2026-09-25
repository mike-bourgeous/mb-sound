module MB
  module Sound
    module Sequence
      # Note length methods added to MB::Sound::Note, so that e.g. `C4.n8` or
      # `C4.quarter.d` returns a one-note Seq.  See Seq for the full list of
      # length methods.
      module NoteMethods
        (Duration::DIVISIONS.map { |k| "n#{k}" } + Duration::NAMES.keys.map(&:to_s)).each do |name|
          define_method(name) { to_seq.public_send(name) }
        end

        [:n, :len, :beats].each do |name|
          define_method(name) { |arg| to_seq.public_send(name, arg) }
        end

        [:d, :dotted, :dd, :double_dotted, :t, :triplet].each do |name|
          define_method(name) { to_seq.public_send(name) }
        end

        # Returns a one-step Seq containing this note, with its length unset.
        def to_seq
          Seq.new([self])
        end
      end
    end
  end
end

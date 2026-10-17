module MB
  module Sound
    module Sequence
      # Clips and grids that remember what plays them (maintainer,
      # 2026-10-17: `bg @l_amen` of a chop clip should play its break): a
      # chop clip (Sample::Slices#chop) plays its slices, a kit design's grid
      # (Drums::Machine#grid) its voices.  #play, #bg, #render, and #write
      # (Playable.graph) play a clip through its #instrument; clips without
      # one play the default patch (Playable::PATCH).
      #
      # The instrument carries over to every clip or grid made from one
      # (`chop.loop.transpose(2).swing(0.2)`), as names don't (see Named):
      # it says what the notes mean (keys of a keymap, voices of a kit), and
      # transforms keep that meaning.  Graph documents print chop clips
      # through their recipe (`brk.chop(...)`, which marks the clip again);
      # `played_by` calls print as written; clips saved as event rows
      # (`events(...)`) don't keep it.
      module PlayedBy
        # The instrument this clip or grid plays on by default (a
        # Sampler::Instrument, Sample::Slices, Sample, SF2 font, or
        # Drums::Machine), or nil.  See #played_by.
        def instrument
          @instrument
        end

        # A copy of this clip or grid that plays on +instrument+ by default
        # (see #instrument): anything with #sampler (an Instrument, Slices,
        # Sample, SF2 font) for clips, or a drum machine with #kit
        # (Drums::TR808, Drums::TR909, a `kit { ... }` design) for clips and
        # grids.  nil removes it.
        #
        #     riff = seq(C4, E4, G4).n8.loop.played_by(sf2('GM.sf2', 'Strings'))
        #     play riff                         # on the strings, not the default saw
        #     play grid(16, kick: 'x...x...', clap: '....x...').played_by(Drums::TR909)
        def played_by(instrument)
          if is_a?(Kit) && !(instrument.nil? || instrument.respond_to?(:kit))
            raise ArgumentError, "A grid is played by a drum machine like Drums::TR909 or `kit { ... }` (got #{instrument.class})"
          end
          unless instrument.nil? || instrument.respond_to?(:sampler) || instrument.respond_to?(:kit)
            raise ArgumentError, "A clip is played by an instrument, slices, a sample, or a drum machine (got #{instrument.class})"
          end

          dup.tap { |c| c.send(:instrument!, instrument) }
        end

        private

        # Sets the instrument of this new copy (see #played_by).
        def instrument!(instrument)
          @instrument = instrument
          @cycle_cache = {} if instance_variable_defined?(:@cycle_cache)
        end

        # Methods never wrapped by .carry! (readers, and the methods above).
        SKIP = [:instrument, :played_by, :source, :lineage, :named, :name, :each, :events, :rows, :[], :steps].freeze

        # Wraps the public methods of +klass+ that may return a clip or grid
        # so their results keep this one's #instrument (see the module
        # description).  Called once everything that adds clip methods has
        # loaded (lib/mb/sound.rb), before graph recipes wrap them.
        def self.carry!(klass)
          names = klass.public_instance_methods - Object.public_instance_methods - Enumerable.public_instance_methods - SKIP
          names = names.reject { |n| n.end_with?('?', '=', '!') || n.start_with?('to_') }
          mod = Module.new
          names.each do |n|
            mod.module_eval <<~RUBY, __FILE__, __LINE__ + 1
              def #{n}(...)
                r = super
                return r if @instrument.nil? || r.equal?(self) || !(r.is_a?(Clip) || r.is_a?(Kit)) || !r.instrument.nil?
                r.played_by(@instrument)
              end
            RUBY
          end
          klass.prepend(mod)
        end
      end
    end
  end
end

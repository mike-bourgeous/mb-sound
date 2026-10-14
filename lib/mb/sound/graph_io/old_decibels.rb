module MB
  module Sound
    module GraphIO
      # Graph documents before format 3 (see GraphIO::FORMAT) wrote
      # dB-valued arguments as bare numbers, which now mean linear gains
      # (Decibels.gain_of, .db_of).  The Loader passes each call of such a
      # document through .convert, which turns those numbers into the
      # Decibels they meant, so old documents play as they did and save
      # again with `-12.db`.
      module OldDecibels
        # Drum calls whose keyword arguments (and per-voice knob Hashes)
        # may hold +accent+ (and tr808's +more_cowbell+) in dB.
        DRUM_METHODS = %i[tr808 tr909 kit drum_kit voice call].freeze

        # Sample methods taking onset detector options in dB.
        ONSET_METHODS = %i[slices slice chops onsets].freeze

        # Returns [args, kwargs, changed] for a call of +name+ on
        # +receiver+ from an old document.
        def self.convert(receiver, name, args, kwargs)
          changed = false
          if receiver.is_a?(GraphNode::DynamicsMethods)
            args, kwargs, changed = GraphNode::DynamicsMethods.from_old_document(name, args, kwargs)
          end

          old_db = ->(v, sign = 1) { changed = true; Decibels.new(sign * v) }
          bare = ->(v) { v.is_a?(Numeric) && !v.is_a?(Decibels) && v.real? }

          if name == :reverb && bare.(kwargs[:duck])
            # dB of reduction (12) is now the wet gain while ducked (-12.db)
            kwargs = kwargs.merge(duck: old_db.(kwargs[:duck], -1))
          end

          if ONSET_METHODS.include?(name) && receiver.is_a?(MB::Sound::Sample)
            %i[threshold floor].each do |k|
              kwargs = kwargs.merge(k => old_db.(kwargs[k])) if bare.(kwargs[k])
            end
          end

          if name == :chorus && bare.(kwargs[:hiss])
            kwargs = kwargs.merge(hiss: old_db.(kwargs[:hiss]))
          end

          if name == :formant || name == :vowel
            # Custom vowels: five [Hz, dB, bandwidth] triples
            args = args.map { |v|
              next v unless v.is_a?(Array) && v.all? { |f| f.is_a?(Array) && f.length == 3 }
              v.map { |f| bare.(f[1]) ? [f[0], old_db.(f[1]), f[2]] : f }
            }
          end

          if DRUM_METHODS.include?(name)
            kwargs = kwargs.to_h { |k, v|
              if (k == :accent || k == :more_cowbell) && bare.(v)
                [k, old_db.(v)]
              elsif v.is_a?(Hash) && bare.(v[:accent])
                [k, v.merge(accent: old_db.(v[:accent]))]
              else
                [k, v]
              end
            }
          end

          [args, kwargs, changed]
        end
      end
    end
  end
end

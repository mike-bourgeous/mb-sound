require 'json'
require 'fileutils'

module MB
  module Sound
    class Session
      module Cue
        # Per-user CUE preferences (cue.json next to the listening level in
        # Internal.help_data_dir): the starting :cue_mix (0 CUE only unless
        # saved; maintainer 2026-10-18: "Default cue only, saveable as a
        # user preference similar to monitor level") and whether the
        # 2-channel split notice was shown.  bin/sound.rb calls .apply at
        # startup (like Help::Level.apply), so scripts and specs start from
        # the defaults.
        module Prefs
          module_function

          def path = File.join(Internal.help_data_dir, 'cue.json')

          # The saved preferences (a Hash with String keys; empty if none).
          def read
            data = JSON.parse(File.read(path))
            data.is_a?(Hash) ? data : {}
          rescue Errno::ENOENT, JSON::ParserError
            {}
          end

          # Merges +values+ into the saved preferences.
          def write(**values)
            data = read.merge(values.transform_keys(&:to_s)).merge('saved' => Time.now.utc.to_s)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, JSON.pretty_generate(data))
            data
          end

          # The saved :cue_mix, or nil.
          def cue_mix
            v = read['cue_mix']
            v.is_a?(Numeric) ? v.to_f.clamp(0.0, 1.0) : nil
          end

          # Saves +value+ (0..1) as the starting :cue_mix and makes it
          # Session.cue_mix_default.  Returns it.
          def save_cue_mix(value)
            raise ArgumentError, "cue_mix must be a number from 0 (CUE only) to 1 (MAIN only) (got #{value.inspect})" unless value.is_a?(Numeric) && value.real? && value >= 0 && value <= 1
            write(cue_mix: value.to_f)
            Session.cue_mix_default = value.to_f
          end

          def split_warned? = read['split_warned'] == true

          def note_split_warned = write(split_warned: true)

          # Sets Session.cue_mix_default from the saved preference (bin/sound.rb
          # at startup).  Returns it.
          def apply
            v = cue_mix
            Session.cue_mix_default = v if v
            Session.cue_mix_default
          end
        end
      end
    end
  end
end

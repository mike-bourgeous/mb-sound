module MB
  module Sound
    class Wavetable
      # Tools for frames: 2D NArrays with one cycle per row (the raw material
      # of cycle-mode Wavetables; see Wavetable.from_samples and
      # Wavetable.from_file), for slicing sounds into cycles, saving and
      # loading, sorting, blurring, and normalizing.  Methods are on
      # Wavetable itself (e.g. Wavetable.normalize(frames)).
      #
      # See bin/make_wavetable.rb.
      module Tools
        # The prefix of a saved table's metadata tags (see .save_frames).
        METADATA_PREFIX = 'mb_sound_wavetable_'

        # Loads an existing wavetable from the given +filename+, using the
        # mb_sound_wavetable_period metadata tag to slice the file.
        #
        # If the file does not have the mb_sound_wavetable_period tag, then the
        # audio is passed into Wavetable.slice_frames to create a wavetable
        # from a normal sound file.  The +:slices+ parameter controls how many
        # slices to ask slice_frames to provide.
        #
        # +:metadata_out+, if a Hash, receives the table's saved metadata
        # (see .save_frames, without the tag prefix) or the slicing details
        # (see .slice_frames).
        def load_frames(filename, slices: 10, ratio: 1.0, metadata_out: nil)
          # Using weighted mixing for now; TODO: find a safe way to combine
          # channels with minimal cancellation of reverb or introduction of high
          # frequency oscillation when normalizing
          metadata = {}
          data = MB::Sound.read(filename, metadata_out: metadata)
          data = data.map.with_index { |c, idx| c / (idx + 1) }.sum

          period = metadata[:mb_sound_wavetable_period]&.to_i
          raise 'Wavetable period must be greater than 1' if period.is_a?(Integer) && period <= 1

          if period
            info = table_metadata(metadata)
            metadata_out&.merge!(info)
            data = data * info[:scale].to_f if info[:scale]
            count = data.length / period
            data[0...(count * period)].reshape(count, period)
          else
            slice_frames(data, slices: slices, ratio: ratio, metadata_out: metadata_out)
          end
        end

        # The wavetable entries of a file's +metadata+ (tags starting with
        # METADATA_PREFIX, without it).
        def table_metadata(metadata)
          metadata.each_with_object({}) { |(k, v), h|
            h[k.to_s.delete_prefix(METADATA_PREFIX).to_sym] = v if k.to_s.start_with?(METADATA_PREFIX)
          }
        end

        # Saves 2D NArray +data+ containing a wavetable to the given sound
        # +filename+, using the mb_sound_wavetable_period tag to record the
        # correct shape of the wavetable.  The rows of the NArray are the entries
        # in the table, and the columns are the audio samples over time.
        #
        # +:metadata+ adds more tags (keys without METADATA_PREFIX; e.g.
        # Wavetable#metadata, or the slicing details from .slice_frames such
        # as the detected frequency and note); the period and frame count
        # are always written.
        def save_frames(filename, data, sample_rate: 48000, overwrite: false, metadata: {})
          raise 'Data must be a 2D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 2

          rows, period = data.shape
          data, scale = fit_for_file(data)
          tags = metadata_tags(metadata.merge(period: period, frames: rows, scale: scale))
          MB::Sound.write(filename, data.reshape(data.length), sample_rate: sample_rate, overwrite: overwrite, metadata: tags)
        end

        # [+data+ scaled to fit a sound file (peaks at most 1), the scale
        # tag that undoes it (nil if unscaled)].  Tables may peak above 1
        # (e.g. the Gibbs overshoot of an exact saw series).
        def fit_for_file(data)
          peak = data.abs.max
          return [data, nil] unless peak > 1

          [data / peak, peak.to_f]
        end

        # File tags for +metadata+ (prefixed keys; values other than numbers
        # and strings as strings).
        def metadata_tags(metadata)
          metadata.compact.each_with_object({}) { |(k, v), h|
            h[:"#{METADATA_PREFIX}#{k}"] = v.is_a?(Numeric) || v.is_a?(String) ? v : v.to_s
          }
        end

        # Slices the given 1D NArray to return a wavetable as a 2D NArray.
        #
        # +:metadata_out+ - An optional unfrozen Hash into which to write
        # information about the wavetable.  Set to nil to disable printing of
        # this info.
        #
        # See bin/make_wavetable.rb.
        def slice_frames(data, freq_range: 30..120, slices: 10, sample_rate: 48000, ratio: 1.0, metadata_out: {})
          # TODO: maybe skip or interpolate over silent slices in the middle of the file
          # TODO: guard against amplifying very high frequency noises e.g. 20k+ dithering noise?
          # TODO: generate a whole bunch of table entries and use k-means clustering to select a few?

          # Chop off leading and trailing silence/near-silence
          original_length = data.length
          data = MB::M.trim(data) { |v| v.abs < -85.db }

          # Estimate frequency and wave period
          freq = MB::Sound.freq_estimate(data, sample_rate: sample_rate, range: freq_range)
          period = ratio.to_f / freq
          xfade = period * 0.25
          period_samples = (period * sample_rate).round
          xfade_samples = (xfade * sample_rate).round
          note = MB::Sound::Tone.new(frequency: freq).to_note

          jump = (data.length - period_samples - xfade_samples) / (slices - 1)

          total_samples = slices * period_samples
          buf = data.class.zeros(total_samples)
          offset = 0

          metadata_out&.merge!({
            original_length: original_length,
            trimmed_silence: original_length - data.length,
            frequency: freq,
            note_name: note.name,
            note_number: note.detuned_number,
            ratio: ratio,
            period: period,
            period_samples: period_samples,
            xfade: xfade,
            xfade_samples: xfade_samples,
          })

          # FIXME: only print this in bin/sound.rb or something; not in rspec
          $stderr.puts MB::U.highlight(metadata_out) if metadata_out

          for start_samples in (0...(data.length - (period_samples + xfade_samples))).step(jump) do
            start_samples = start_samples.floor
            end_samples = start_samples + period_samples
            lead_in_start = MB::M.max(0, start_samples - xfade_samples)
            lead_out_end = end_samples + xfade_samples

            if data.length < start_samples + period_samples + xfade_samples
              # TODO: Allow shortening the lead-out somewhat?
              raise "Sound is too short (must be #{start_samples + period_samples + xfade_samples} samples; got #{data.length} samples)"
            end

            # TODO: try windowing instead of cross-fading as an option?

            # Take lead-in from before the loop (mixed in at the end of the loop)
            if start_samples > 0
              lead_in = data[lead_in_start...start_samples].dup
              lead_in = fade(lead_in, true)
            else
              lead_in = Numo::SFloat[0]
            end

            # Copy loopable segment
            middle = data[start_samples...end_samples].dup

            # Take lead-out from after the loop (mixed in at the start of the loop)
            lead_out = data[end_samples...lead_out_end].dup
            lead_out = fade(lead_out, false)

            # Add lead-in and lead-out to segment
            middle[0...lead_out.length].inplace + lead_out
            middle[-lead_in.length...].inplace + lead_in

            # Normalize and remove DC offset
            middle -= middle.mean
            max = MB::M.max(middle.abs.max, -80.db)
            middle = middle / max

            buf[offset...(offset + period_samples)] = middle
            offset += period_samples
          end

          center(buf.reshape(slices, period_samples).inplace!).not_inplace!
        end

        # Calls a block +:steps+ times to generate a wavetable by passing
        # interpolating parameters to the block.  Sample rate is assumed to be
        # 48kHz.
        #
        # The +:from+ and +:to+ parameters may be anything that MB::M.interp can
        # interpolate.  Interpolation uses the smoothstep curve; use the :curve
        # parameter to change this (nil or ->{it} will be linear).
        #
        # The block will receive the interpolated value for the current step and
        # a Tone object with a period of +:length+ samples.
        #
        # If the block returns a Numo::NArray, then that will be appended to the
        # wavetable.
        #
        # If the block returns a Graph, then it will be sampled for +:length+
        # samples 3 times (to allow for filter stabilization) with the last tone
        # cycle appended to the wavetable (-(length*3/2)...-(length/2)).
        #
        # The :center, :sort, and :normalize parameters enable or disable
        # post-processing by the method of the same name.
        #
        # Examples:
        #     # Square to saw
        #     MB::Sound::Wavetable.generate(fade_edges: false) { |v, _t| MB::M.safe_power(Numo::SFloat.linspace(-1, 1, 2048), v) }
        #
        #     # Harmonics
        #     MB::Sound::Wavetable.generate(from: 2, to: 11, curve: nil) { |v, t| t + (t.frequency * v).hz }
        def generate(steps: 10, from: 0, to: 1, length: 2048, center: false, sort: false, normalize: true, fade_edges: true, curve: MB::M.method(:smoothstep))
          table = Array.new(steps) { |i|
            tone = (48000.0 / length).hz.at(1).with_phase(0.5)
            val = MB::M.interp(from, to, i.to_f / (steps - 1), func: curve)

            ret = yield val, tone
            case ret
            when Numo::NArray
              raise "Wave length must be #{length} samples" unless ret.shape == [2048]
              ret

            when GraphNode
              ret.sample(length)
              ret.sample(length)
              ret.sample(length)

            else
              raise "Unsupported wavetable entry: #{ret.inspect}"
            end
          }

          table = Numo::SFloat.cast(table).inplace!

          table = normalize(table) if normalize
          table = sort(table) if sort

          table = fade_edges(table) if fade_edges && center
          table = center(table) if center
          table = fade_edges(table) if fade_edges

          table.not_inplace!
        end

        # Fades +clip+ in or out in-place.  For .slice_frames.
        def fade(clip, fade_in)
          fade = MB::FastSound.smootherstep_buf(Numo::SFloat.zeros(clip.length))
          fade = 1 - fade.inplace unless fade_in
          clip.inplace * fade.not_inplace!
        end

        # Blends the edges of each entry in +table+ to temper clicks for waves
        # that aren't perfectly periodic or have discontinuities at the edge.
        #
        # Fades the first and last 1/64th of the buffer, with a minimum fade of 4
        # samples.  Doesn't modify tables shorter than 8 samples.
        def fade_edges(table)
          raise 'Wavetable must be a 2D Numo::NArray' unless table.is_a?(Numo::NArray) && table.ndim == 2

          # FIXME: make this look right for all of these:
          # t = MB::Sound::Wavetable.generate { |v, t| t.fm(v.constant) }
          # t = MB::Sound::Wavetable.generate(steps: 100, normalize: false) { |v, t| Numo::SFloat.zeros(2048).fill(v) }
          #
          # Idea: subtract a smoothstep or linear element across the fade range,
          # preserving some higher frequencies but ending at the same value as
          # the beginning.  This might be made idempotent(?)
          #
          # Idea 2: ignore the midpoint value and just blend between the end
          # values

          rows, cols = table.shape

          return table if cols < 8

          table = table.dup unless table.inplace?

          fade_cols = cols / 64
          fade_cols = 4 if fade_cols < 4

          fade_buf = MB::FastSound.smootherstep_buf(Numo::SFloat.zeros(fade_cols * 2))
          fade_in_buf = (fade_buf[fade_cols..-1].inplace! * 2 - 1).not_inplace!
          fade_out_buf = (1 - fade_buf[0...fade_cols].inplace! * 2).not_inplace!

          rows.times do |row|
            wave = table[row, nil]

            intro = wave[0...fade_cols].inplace!
            outro = wave[-fade_cols..-1].inplace!

            mid = 0.5 * (intro[0] + outro[-1])

            intro * fade_in_buf + mid * (1 - fade_in_buf)
            outro * fade_out_buf + mid * (1 - fade_out_buf)
          end

          table
        end

        # Creates a new wavetable that blends each row in the given +wavetable+
        # with adjacent rows.  A strength of 1.0 means an equal blend of the
        # three rows.  As strength approaches infinity the original row fades
        # away.
        #
        # You should probably use .normalize after this method to ensure the
        # wavetable maintains a consistent peak amplitude.
        def blur(wavetable, strength)
          raise 'Wavetable must be a 2D Numo::NArray' unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2

          new_table = wavetable.dup

          w_other = strength
          w_self = 1.0
          w_total = w_self + 2 * w_other.abs
          w_self /= w_total
          w_other /= w_total

          rows = wavetable.shape[0]

          for row in 0...rows
            r1 = wavetable[row - 1, nil]
            r2 = wavetable[row, nil]
            r3 = wavetable[row == rows - 1 ? 0 : row + 1, nil]

            new_table[row, nil] = (r1 + r3) * w_other + r2 * w_self
          end

          new_table
        end

        # Sorts a +wavetable+ by spectral slope and returns the sorted copy.  In
        # this case spectral slope is the slope component of a linear regression
        # on the frequency spectrum of the wave.  This should, roughly, place
        # brighter and noisier waves at the end of the table (or at the start if
        # +:reverse+ is true).
        def sort(wavetable, reverse: false)
          indices = (0...wavetable.shape[0]).to_a

          # TODO: debug this; it doesn't put drums in the order I would expect.
          # It might be better to define a crossover point and sort by the ratio
          # between the areas above and below that point.
          indices.sort_by! { |row|
            fft = MB::Sound.real_fft(wavetable[row, nil]).abs
            slope, _ = MB::M.linear_regression(fft)
            slope
          }

          indices.reverse! if reverse

          Numo::SFloat.cast(
            indices.map { |row|
              wavetable[row, nil].dup
            }
          )
        end

        # Removes DC offset and rescales each row of the given +wavetable+ to the
        # given +max+ amplitude.  Modifies the wavetable in place and returns it.
        #
        # TODO: allow normalizing RMS with waveshaping?
        def normalize(wavetable, max = 1.0)
          raise 'Wavetable must be a 2D Numo::NArray' unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2

          for row in 0...wavetable.shape[0]
            data = wavetable[row, nil]
            data -= data.mean
            rowmax = MB::M.max(-80.db, data.abs.max)
            wavetable[row, nil] = data * (max / rowmax)
          end

          wavetable
        end

        # Performs per-row centering to place each wave's first zero crossing in
        # the middle of the buffer.  Returns the existing wavetable if it was
        # marked as in-place, or a copy if it wasn't.  Raises an error if there
        # is no zero crossing (could be caused by silence, DC offset).
        #
        # TODO: find the closest zero crossing to the existing center in either
        # direction?
        def center(wavetable)
          raise 'Wavetable must be a 2D Numo::NArray' unless wavetable.is_a?(Numo::NArray) && wavetable.ndim == 2

          wavetable = wavetable.dup unless wavetable.inplace?

          for row in 0...wavetable.shape[0]
            wave = wavetable[row, nil]

            zc_index = MB::M.find_zero_crossing(wave)
            if zc_index.nil? && wave[-1] < 0 && wave[0] >= 0
              # TODO: should find_zero_crossing wrap around like this?
              zc_index = 0
            end

            raise "No zero crossing found for row #{row} (min/max: #{wave.minmax})" unless zc_index

            wavetable[row, nil] = MB::M.rol(wave, zc_index - wave.length / 2)
          end

          wavetable
        end

      end

      extend Tools
    end
  end
end

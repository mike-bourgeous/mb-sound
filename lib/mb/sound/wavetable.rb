module MB
  module Sound
    # Methods related to saving, loading, generating, and sampling from
    # wavetables.
    #
    # See MB::Sound::GraphNode::Wavetable.
    # See bin/make_wavetable.rb.
    module Wavetable
      # Loads an existing wavetable from the given +filename+, using the
      # mb_sound_wavetable_period metadata tag to slice the file.
      #
      # If the file does not have the mb_sound_wavetable_period tag, then the
      # audio is passed into Wavetable.make_wavetable to create a wavetable
      # from a normal sound file.  The +:slices+ parameter controls how many
      # slices to ask make_wavetable to provide.
      def self.load_wavetable(filename, slices: 10, ratio: 1.0)
        # Using weighted mixing for now; TODO: find a safe way to combine
        # channels with minimal cancellation of reverb or introduction of high
        # frequency oscillation when normalizing
        metadata = {}
        data = MB::Sound.read(filename, metadata_out: metadata)
        data = data.map.with_index { |c, idx| c / (idx + 1) }.sum

        period = metadata[:mb_sound_wavetable_period]&.to_i
        raise 'Wavetable period must be greater than 1' if period.is_a?(Integer) && period <= 1

        if period
          count = data.length / period
          data[0...(count * period)].reshape(count, period)
        else
          make_wavetable(data, slices: slices, ratio: ratio)
        end
      end

      # Saves 2D NArray +data+ containing a wavetable to the given sound
      # +filename+, using the mb_sound_wavetable_period tag to record the
      # correct shape of the wavetable.  The rows of the NArray are the entries
      # in the table, and the columns are the audio samples over time.
      def self.save_wavetable(filename, data, sample_rate: 48000, overwrite: false)
        raise 'Data must be a 2D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 2

        period = data.shape[1]
        total = data.length
        # TODO: Add all metadata to the file including root note, etc.
        MB::Sound.write(filename, data.reshape(total), sample_rate: sample_rate, overwrite: overwrite, metadata: { mb_sound_wavetable_period: period })
      end

      # Slices the given 1D NArray to return a wavetable as a 2D NArray.
      #
      # +:metadata_out+ - An optional unfrozen Hash into which to write
      # information about the wavetable.  Set to nil to disable printing of
      # this info.
      #
      # See bin/make_wavetable.rb.
      def self.make_wavetable(data, freq_range: 30..120, slices: 10, sample_rate: 48000, ratio: 1.0, metadata_out: {})
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
      def self.generate(steps: 10, from: 0, to: 1, length: 2048, center: false, sort: false, normalize: true, fade_edges: true, curve: MB::M.method(:smoothstep))
        table = Array.new(steps) { |i|
          tone = (48000.0 / length).hz.at(1).with_phase(Math::PI)
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

      # Fades +clip+ in or out in-place.  For .make_wavetable.
      def self.fade(clip, fade_in)
        fade = MB::FastSound.smootherstep_buf(Numo::SFloat.zeros(clip.length))
        fade = 1 - fade.inplace unless fade_in
        clip.inplace * fade.not_inplace!
      end

      # Blends the edges of each entry in +table+ to temper clicks for waves
      # that aren't perfectly periodic or have discontinuities at the edge.
      #
      # Fades the first and last 1/64th of the buffer, with a minimum fade of 4
      # samples.  Doesn't modify tables shorter than 8 samples.
      def self.fade_edges(table)
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
      def self.blur(wavetable, strength)
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
      def self.sort(wavetable, reverse: false)
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
      def self.normalize(wavetable, max = 1.0)
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
      def self.center(wavetable)
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

      # TODO: functions to shuffle and stretch/interpolate wavetables?
      # TODO: functions for spectral changes to wavetables?
      # TODO: mip-mapped or note-range wavetables
      # TODO: midi/realtime control of wavetable wrapping mode?
      # TODO: blend between wrapping modes by output
      # TODO: warp between wrapping modes by blending lookup indices?
      # FIXME: make it super easy to play the full cycle including cubic
      # overshoot, and make the areas around that more musical somehow (getting
      # clicking and very sharp waves if the phase is off just a tiny bit); it
      # might be better to create a true wavetable oscillator that knows when
      # it's wrapping around early and feeds the wrapped samples into the cubic
      # interpolator instead of feeding in samples beyond where the phase will
      # actually wrap
      # FIXME: glitch at the bottom CC range of play
      # ((midi.hz.ramp.at(1)).wavetable(wavetable: wt2, number:
      # midi.cc(1).spy{|v|puts v.minmax}, wrap: :wrap) *
      # midi.gate).softclip.filter(:highpass, cutoff: 20, quality:
      # 0.7).oversample(2) -- it seems to be wrapping around partially when it
      # should be on the first wave; might be caused by wrapping around blur

      # Performs a fractional wavetable lookup with wraparound.
      #
      # :number - A 1D Numo::NArray with the wave number (from 0..1) over time
      # :phase - A 1D Numo::NArray with the wave phase (from 0..1) over time
      # :lookup - Interpolation method (:linear or :cubic)
      # :wrap - Wrapping method (:wrap, :bounce, :clamp, or :zero)
      #
      # See MB::Sound::GraphNode#wavetable.
      def self.wavetable_lookup(wavetable:, number:, phase:, lookup:, wrap:)
        wavetable_lookup_c(wavetable: wavetable, number: number, phase: phase, lookup: lookup, wrap: wrap)
      end

      # Ruby implementation of .wavetable_lookup.
      def self.wavetable_lookup_ruby(wavetable:, number:, phase:, lookup:, wrap:)
        raise 'Number and phase must be the same size array' unless number.length == phase.length

        case lookup
        when :cubic
          number.map_with_index do |num, idx|
            phi = phase[idx]
            outer_cubic_ruby(wavetable: wavetable, number: num, phase: phi, wrap: wrap)
          end

        when :linear
          number.map_with_index do |num, idx|
            phi = phase[idx]
            outer_linear_ruby(wavetable: wavetable, number: num, phase: phi, wrap: wrap)
          end

        else
          raise ArgumentError, "Invalid wavetable lookup mode: #{lookup.inspect}"
        end
      end

      # C extension implementation of .wavetable_lookup.
      def self.wavetable_lookup_c(wavetable:, number:, phase:, lookup:, wrap:)
        MB::Sound::FastWavetable.wavetable_lookup(wavetable, number, phase, lookup, wrap)
      end

      # Interpolates waves and samples from the wavetable.  See also
      # #wavetable_lookup.
      #
      # :number - Fractional wave number from 0 to 1.
      # :phase - Time index from 0 to 1.
      # :wrap - Wrapping mode (:wrap, :clamp, :bounce, :zero)
      def self.outer_linear(wavetable:, number:, phase:, wrap:)
        outer_linear_c(wavetable: wavetable, number: number, phase: phase, wrap: wrap)
      end

      # Interpolates waves and samples from the wavetable using cubic
      # interpolation.  See also #wavetable_lookup.
      #
      # :number - Fractional wave number from 0 to 1.
      # :phase - Time index from 0 to 1.
      # :wrap - Wrapping mode (:wrap, :clamp, :bounce, :zero)
      def self.outer_cubic(wavetable:, number:, phase:, wrap:)
        outer_cubic_c(wavetable: wavetable, number: number, phase: phase, wrap: wrap)
      end

      # Uses cubic interpolation to blend across samples and waves in the given
      # +:wavetable+, as opposed to linear interpolation used by
      # #outer_linear_ruby.
      def self.outer_cubic_ruby(wavetable:, number:, phase:, wrap:)
        rows = wavetable.shape[0]
        cols = wavetable.shape[1]

        frow = (number * (rows - 1)) % rows
        row1 = frow.floor
        row2 = row1 + 1
        row1 %= rows
        row2 %= rows
        rowratio = frow - row1

        fcol = (phase + 1) / 2 * cols

        vtop = MB::M.cubic_lookup(wavetable[row1, nil], fcol, mode: wrap)
        vbot = MB::M.cubic_lookup(wavetable[row2, nil], fcol, mode: wrap)

        # TODO: smoothstep or cubic between waves?
        vbot * rowratio + vtop * (1.0 - rowratio)
      end

      # Ruby implementation of .outer_linear.
      def self.outer_linear_ruby(wavetable:, number:, phase:, wrap:)
        wave_count = wavetable.shape[0]
        sample_count = wavetable.shape[1]

        frow = (number * (wave_count - 1)) % wave_count
        row1 = frow.floor
        row2 = row1 + 1
        row1 %= wave_count
        row2 %= wave_count
        rowratio = frow - row1

        fcol = (phase + 1) / 2 * sample_count
        col1 = fcol.floor
        col2 = col1 + 1
        colratio = fcol - col1

        val1l = MB::M.fetch_oob(wavetable[row1, nil], col1, mode: wrap)
        val1r = MB::M.fetch_oob(wavetable[row1, nil], col2, mode: wrap)
        val2l = MB::M.fetch_oob(wavetable[row2, nil], col1, mode: wrap)
        val2r = MB::M.fetch_oob(wavetable[row2, nil], col2, mode: wrap)

        valtop = val1r * colratio + val1l * (1.0 - colratio)
        valbot = val2r * colratio + val2l * (1.0 - colratio)

        # TODO: smoothstep between waves?
        valbot * rowratio + valtop * (1.0 - rowratio)
      end

      # C extension implementation of .outer_linear.
      def self.outer_linear_c(wavetable:, number:, phase:, wrap:)
        MB::Sound::FastWavetable.outer_linear(wavetable, number, phase, wrap)
      end

      # C extension implementation of .outer_cubic.
      def self.outer_cubic_c(wavetable:, number:, phase:, wrap:)
        MB::Sound::FastWavetable.outer_cubic(wavetable, number, phase, wrap)
      end
    end
  end
end

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
        puts MB::U.highlight(metadata_out) if metadata_out

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
          middle -= (middle.sum / middle.length)
          max = MB::M.max(middle.abs.max, -80.db)
          middle = (middle / max) * -2.db

          # Rotate phase to put positive zero crossing at beginning/end
          zc_index = MB::M.find_zero_crossing(middle)
          middle = MB::M.rol(middle, zc_index) if zc_index

          buf[offset...(offset + period_samples)] = middle
          offset += period_samples
        end

        buf.reshape(slices, period_samples)
      end

      # Fades +clip+ in or out in-place.  For .make_wavetable.
      def self.fade(clip, fade_in)
        fade = MB::FastSound.smootherstep_buf(Numo::SFloat.zeros(clip.length))
        fade = 1 - fade.inplace unless fade_in
        clip.inplace * fade.not_inplace!
      end

      # TODO: functions to sort wavetables by brightness, etc.?
      # TODO: functions to shuffle wavetables?
      # TODO: generate a whole bunch of table entries and use k-means clustering to select a few?
      # TODO: move make_wavetable.rb functionality into a function here
      # TODO: optimized C version?

      # Performs a fractional wavetable lookup with wraparound.
      #
      # :number - A 1D Numo::NArray with the wave number (from 0..1) over time
      # :phase - A 1D Numo::NArray with the wave phase (from 0..1)over time
      #
      # TODO: bouncing or zero-extending?
      #
      # See MB::Sound::GraphNode#wavetable.
      def self.wavetable_lookup(wavetable:, number:, phase:)
        wavetable_lookup_ruby(wavetable: wavetable, number: number, phase: phase)
      end

      # Ruby implementation of .wavetable_lookup.
      def self.wavetable_lookup_ruby(wavetable:, number:, phase:)
        raise 'Number and phase must be the same size array' unless number.length == phase.length

        $wavetable_mode ||= :cubic
        if $wavetable_mode == :cubic
          number.map_with_index do |num, idx|
            phi = phase[idx]
            outer_cubic_ruby(wavetable: wavetable, number: num, phase: phi)
          end
        else
          number.map_with_index do |num, idx|
            phi = phase[idx]
            outer_linear_ruby(wavetable: wavetable, number: num, phase: phi)
          end
        end
      end

      # C extension implementation of .wavetable_lookup.
      def self.wavetable_lookup_c(wavetable:, number:, phase:)
        #phase = phase.dup.inplace! unless phase.inplace?
        MB::Sound::FastWavetable.wavetable_lookup(wavetable, number, phase)
      end

      # Interpolates waves and samples from the wavetable.  See also
      # #wavetable_lookup.
      #
      # :number - Fractional wave number from 0 to 1.
      # :phase - Time index from 0 to 1.
      def self.outer_linear(wavetable:, number:, phase:)
        outer_linear_ruby(wavetable: wavetable, number: number, phase: phase)
      end

      # Uses cubic interpolation to blend across samples and waves in the given
      # +:wavetable+, as opposed to linear interpolation used by
      # #outer_linear_ruby.
      #
      # TODO: cubic across waves; currently linear; probably requires 16
      # lookups instead of linear's 4
      def self.outer_cubic_ruby(wavetable:, number:, phase:)
        rows = wavetable.shape[0].to_f
        cols = wavetable.shape[1].to_f

        frow = (number * rows) % rows
        row1 = frow.floor
        row2 = frow.ceil
        row1 %= rows
        row2 %= rows
        rowratio = frow - row1

        fcol = phase * cols

        # TODO: allow choosing oob mode from parameters
        $wavetable_wrap ||= :wrap
        vtop = MB::M.cubic_lookup(wavetable[row1, nil], fcol, mode: $wavetable_wrap || :bounce)
        vbot = MB::M.cubic_lookup(wavetable[row2, nil], fcol, mode: $wavetable_wrap || :bounce)

        vbot * rowratio + vtop * (1.0 - rowratio)
      end

      # Ruby implementation of .outer_linear.
      def self.outer_linear_ruby(wavetable:, number:, phase:)
        wave_count = wavetable.shape[0]
        sample_count = wavetable.shape[1]

        frow = (number * wave_count) % wave_count
        row1 = frow.floor
        row2 = frow.ceil
        row1 %= wave_count
        row2 %= wave_count
        rowratio = frow - row1

        fcol = (phase % 1.0) * sample_count
        col1 = fcol.floor
        col2 = fcol.ceil
        col1 %= sample_count
        col2 %= sample_count
        colratio = fcol - col1

        val1l = wavetable[row1, col1]
        val1r = wavetable[row1, col2]
        val2l = wavetable[row2, col1]
        val2r = wavetable[row2, col2]

        valtop = val1r * colratio + val1l * (1.0 - colratio)
        valbot = val2r * colratio + val2l * (1.0 - colratio)

        valbot * rowratio + valtop * (1.0 - rowratio)
      end

      # C extension implementation of .outer_linear.
      def self.outer_linear_c(wavetable:, number:, phase:)
        MB::Sound::FastWavetable.outer_lookup(wavetable, number, phase)
      end
    end
  end
end

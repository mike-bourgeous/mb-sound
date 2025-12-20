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
        metadata = {}
        data = MB::Sound.read(filename, metadata_out: metadata)
        data = data.sum / data.length

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
      def self.make_wavetable(data, freq_range: 30..120, slices: 10, sample_rate: 48000, ratio: 1.0)
        # TODO: maybe chop off leading and trailing silence/near-silence
        # TODO: maybe skip or interpolate over silent slices
        # TODO: guard against amplifying very high frequency noises e.g. 20k+ dithering noise?

        # Estimate frequency and wave period
        # TODO: return this extra info somehow
        freq = MB::Sound.freq_estimate(data, sample_rate: sample_rate, range: freq_range)
        period = ratio.to_f / freq
        xfade = period * 0.25
        period_samples = (period * sample_rate).round
        xfade_samples = (xfade * sample_rate).round
        note_name = MB::Sound::Tone.new(frequency: freq).to_note.name

        jump = (data.length - period_samples - xfade_samples) / (slices - 1)

        total_samples = slices * period_samples
        buf = data.class.zeros(total_samples)
        offset = 0

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
          max = MB::M.max(middle.abs.max, -60.db)
          middle = (middle / max) * -2.db

          # Rotate phase to put positive zero crossing at beginning/end
          zc_index = MB::M.find_zero_crossing(middle)
          looped = MB::M.rol(middle, zc_index) if zc_index

          buf[offset...(offset + period_samples)] = looped
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
        wavetable_lookup_c(wavetable: wavetable, number: number, phase: phase)
      end

      # Ruby implementation of .wavetable_lookup.
      def self.wavetable_lookup_ruby(wavetable:, number:, phase:)
        raise 'Number and phase must be the same size array' unless number.length == phase.length

        number.map_with_index do |num, idx|
          phi = phase[idx]
          outer_lookup_ruby(wavetable: wavetable, number: num, phase: phi)
        end
      end

      # C extension implementation of .wavetable_lookup.
      def self.wavetable_lookup_c(wavetable:, number:, phase:)
        #phase = phase.dup.inplace! unless phase.inplace?
        MB::Sound::FastWavetable.wavetable_lookup(wavetable, number, phase)
      end

      # Blends two columns within a single row of the wavetable.  You should
      # probably use .wavetable_lookup or .outer_lookup.
      #
      # :number - The wave number index, which should be an integer.
      # :phase - Time index from 0 to 1.
      #
      # TODO: bouncing or zero-extending?
      def self.inner_lookup(wavetable:, number:, phase:)
        row = number.floor

        fcol = (phase % 1.0) * wavetable.shape[1]
        col1 = fcol.floor
        col2 = fcol.ceil
        col1 %= wavetable.shape[1]
        col2 %= wavetable.shape[1]

        ratio = fcol - col1

        val1 = wavetable[row, col1]
        val2 = wavetable[row, col2]

        val2 * ratio + val1 * (1.0 - ratio)
      end

      # Blends two waves using #inner_lookup.  See also #wavetable_lookup.
      #
      # :number - Fractional wave number from 0 to 1.
      # :phase - Time index from 0 to 1.
      def self.outer_lookup(wavetable:, number:, phase:)
        outer_lookup_c(wavetable: wavetable, number: number, phase: phase)
      end

      # Ruby implementation of .outer_lookup.
      def self.outer_lookup_ruby(wavetable:, number:, phase:)
        wave_count = wavetable.shape[0]
        frow = (number * wave_count) % wave_count
        row1 = frow.floor
        row2 = frow.ceil
        row1 %= wave_count
        row2 %= wave_count

        ratio = frow - row1

        val1 = inner_lookup(wavetable: wavetable, number: row1, phase: phase)
        val2 = inner_lookup(wavetable: wavetable, number: row2, phase: phase)

        val2 * ratio + val1 * (1.0 - ratio)
      end

      # C extension implementation of .outer_lookup.
      def self.outer_lookup_c(wavetable:, number:, phase:)
        MB::Sound::FastWavetable.outer_lookup(wavetable, number, phase)
      end
    end
  end
end

#!/usr/bin/env ruby
# An experimental FM synthesizer that uses later notes to modulate earlier notes.
# (C)2021 Mike Bourgeous

require 'bundler/setup'

require 'mb-sound'

class FM
  def initialize(osc_count: 8, jack: MB::Sound::JackFFI[], input: nil, update_rate: 60)
    @manager = MIDI::Manager(jack: jack, input: input, update_rate: update_rate)
    @manager.on_note(&method(:note))

    # TODO: modulation index CC

    @oscillators = osc_count.times.map { |o|
      440.hz.at(-10.db).oscillator
    }
    @oscs_used = 0
    @osc_map = {}

    @freq_mixers = (osc_count - 1).times.map { |o|
      MB::Sound::Mixer.new([])
    }

    @output_mixer = MB::Sound::Mixer.new([], buffer_size: jack.buffer_size)
  end

  def print
    MB::U.headline('Oscillators')
    MB::U.table(
      @oscillators.map { |o|
        [
          o.__id__,
          o.number,
          o.frequency,
          o.wave_type,
          @output_mixer[o]
        ]
      },
      header: [:id, :number, :frequency, :wave_type, :gain]
    )

    MB::U.headline('Mixers')
    MB::U.table(
      @freq_mixers.map { |m|
        [
          m.__id__,
          m.constant,
          m.summands.map(&:__id__),
          m.gains
        ]
      },
      header: [:id, :constant, :summands, :gains],
    )
  end

  def note(number, velocity, onoff)
    if onoff
      if @oscs_used < @oscillators.length
        osc = @oscillators[@oscs_used]
        osc.number = number
        @output_mixer[osc] = MB::M.scale(velocity, 0..127, -30..-6).db
        @osc_map[number] = osc

        if @oscs_used > 0
          # Wire this oscillator as FM modulator for the previous oscillator
          prev = @oscillators[@oscs_used - 1]

          mixer = @freq_mixers[@oscs_used - 1]
          mixer.clear
          mixer.constant = prev.frequency

          prev.frequency = mixer
        end

        @oscs_used += 1
      end
    else
      osc = @osc_map.delete(number)
      if osc
        # Mute the oscillator
        @output_mixer[osc] = 0

        if osc.frequency.is_a?(MB::Sound::Mixer)
          mixer = osc.frequency
        end

        index = @oscillators.index(osc)

        if index > 0
          prev = @oscillators[index - 1]

          # Disconnect this oscillator from its FM output
          prev_mixer = prev.frequency
          raise 'BUG: prev freq is not a mixer' unless prev_mixer.is_a?(MB::Sound::Mixer)

          if mixer
            # Bypass this oscillator for its FM input (wire it to the previous oscillator)
            next_osc = mixer.summands.last

            prev_mixer.clear
            prev_mixer[next_osc] = mixer[next_osc]

            @freq_mixers.delete(mixer)
            @freq_mixers << mixer
          end
        end

        osc.release(number, velocity)

        @oscillators.delete(osc)
        @oscillators << osc
      end
    end
  end

  def sample(count)
    @manager.update
    @output_mixer.sample(count).real
  end
end

synth = FM.new


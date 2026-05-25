#!/usr/bin/env ruby
# An experimental FM synthesizer that uses later notes to modulate earlier
# notes.  If only one note is played, that note is unmodulated.  Each later
# note modulates the note that came before it.  The modulation wheel controls
# the intensity of modulation.
# (C)2021 Mike Bourgeous

require 'bundler/setup'

require 'mb-sound'

MB::U.sigquit_backtrace

class FM
  def initialize(osc_count: 8, jack: MB::Sound::JackFFI[], input: nil, connect: nil, update_rate: 60)
    @manager = MB::Sound::MIDI::Manager.new(jack: jack, input: input, connect: connect, update_rate: update_rate)
    @manager.on_note(&method(:note))

    @manager.on_cc(1, range: 0.0..10000) do |mod|
      @mod_index = mod
      @oscillators.each do |o|
        o.frequency[0] = @mod_index unless o.frequency.empty?
      end
    end

    @oscillators = osc_count.times.map { |o|
      # Parabola is a little more interesting than sine without being too chaotic
      o = 440.hz.parabola.at(-10.db).oscillator
      o.frequency = MB::Sound::GraphNode::Mixer.new([], sample_rate: 48000)
      o
    }
    @oscs_used = 0
    @osc_map = {}

    @mod_index = 1000
  end

  def print
    MB::U.headline("Oscillators (#{@oscs_used} in use)")
    MB::U.table(
      @oscillators.map { |o|
        [
          o.__id__,
          o.wave_type,
          o.frequency.constant.round(3),
          o.frequency.summands.map(&:__id__),
          o.frequency.gains,
        ]
      },
      header: [:id, :wave_type, :frequency, :modulator, :mod_gain],
      variable_width: true
    )
  end

  def note(number, velocity, on)
    if on
      note(number, velocity, false) if @osc_map.include?(number)

      if @oscs_used < @oscillators.length
        osc = @oscillators[@oscs_used]
        @osc_map[number] = osc

        osc.frequency.constant = MB::Sound::Oscillator.calc_freq(number)
        osc.frequency.clear

        if @oscs_used > 0
          # Wire this oscillator as FM modulator for the previous oscillator
          prev = @oscillators[@oscs_used - 1]
          prev.frequency.clear
          prev.frequency[osc] = @mod_index
        end

        @oscs_used += 1
      end
    else
      osc = @osc_map.delete(number)
      if osc
        index = @oscillators.index(osc)

        if index > 0
          prev = @oscillators[index - 1]

          # Disconnect this oscillator from the FM chain
          prev.frequency.clear

          next_osc = osc.frequency.summands.first
          prev.frequency[next_osc] = @mod_index if next_osc
        end

        osc.frequency.clear

        @oscillators.delete(osc)
        @oscillators << osc

        @oscs_used -= 1
      end
    end
  end

  def sample(count)
    @zero ||= Numo::SFloat.zeros(count)
    @manager.update
    @oscillators[0].sample(count) * (@oscs_used > 0 ? 1 : 0)
  end
end

output = MB::Sound::JackFFI[].output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
synth = FM.new(update_rate: output.sample_rate.to_f / output.buffer_size, connect: ARGV[0])

puts "\n" * MB::U.height

PLOT = ENV['PLOT'] != '0'

begin
  t = 0
  loop do
    data = synth.sample(output.buffer_size)

    if t % 20 == 0
      puts "\e[H"
      synth.print

      if PLOT
        MB::Sound.plot([data, MB::Sound.real_fft(data).abs], graphical: true)
      end
    end

    t += 1

    output.write([data])
  end
ensure
  puts "\n" * MB::U.height
end

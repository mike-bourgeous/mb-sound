#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plots the same function upsampled by all the different resampling modes,
# showing the stairstep and jagged line effects of ZOH and linear resamplers
# compared to the smooth sine wave of a sinc resampler.

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

MB::Sound.script(
  args: 0,
  graphical: [false, 'Plot as an inline terminal image (iTerm2, kitty, sixel) and redraw every 2 seconds'],
  spectrum: [false, 'Plot magnitude and phase spectra instead of time and frequency'],
) { |_, p|
  graphical = p.graphical
  spectrum = p.spectrum

  data = MB::Sound::GraphNode::Resample::MODES.map { |m|
    d = 40.hz.at(1).at_rate(400).resample(16000, mode: m).sample(65000)
    [
      m,
      MB::M.skip_leading(d, 0)[0...64000]
    ]
  }.to_h

  pry_next = false
  MB::U.sigquit_backtrace {
    pry_next = true
    Thread.new do |t| sleep 0.1 ; Thread.main.wakeup end
  }

  loop do
    if spectrum
      MB::Sound.mag_phase(
        data,
        graphical: graphical,
        freq_samples: 16000
      )
    else
      MB::Sound.time_freq(
        data,
        graphical: graphical,
        time_samples: 1600,
        freq_samples: 16000
      )
    end

    sleep 2

    if pry_next
      binding.pry
      pry_next = false
    end

    # Graphical mode redraws every 2 seconds (as an inline image where the
    # terminal supports one)
    break unless graphical
  end
}

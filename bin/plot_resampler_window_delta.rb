#!/usr/bin/env ruby
# Plots difference between resampling with a large buffer size and a small
# buffer size.  There shouldn't be a difference, but at time of writing this
# script there is.

# TODO: dedupe with other plot_resampler* scripts?

require 'bundler/setup'

require 'pry-byebug'

require 'mb-sound'

pry_next = false
MB::U.sigquit_backtrace {
  pry_next = true
  Thread.new do |t| sleep 0.1 ; Thread.main.wakeup end
}

MB::Sound.script(
  args: 0,
  graphical: [false, 'Plot in a graphical window (and redraw every 2 seconds)'],
  spectrum: [false, 'Plot magnitude and phase spectra instead of time and frequency'],
  samples: [108000, 'Samples to analyze', 1..],
  time_samples: [nil, Integer, 'Samples in the time plot (default: a tenth of --samples)'],
  from_rate: [400, 'Original sample rate', 1..],
  to_rate: [17000, 'Resampled rate', 1..],
  freq: [40.0, 'Test tone frequency in Hz'],
  multi_samples: [216, 'Samples per multi_sample call', 1..],
) { |_, p|
  graphical = p.graphical
  spectrum = p.spectrum
  samples = p.samples
  time_samples = p.time_samples || samples / 10
  from_rate = p.from_rate
  to_rate = p.to_rate
  freq = p.freq
  multi_samples = p.multi_samples || samples
  multi_count = (samples * 1.1 / multi_samples).ceil

  modes = [
    :ruby_zoh,
    :ruby_linear,
    :libsamplerate_zoh,
    :libsamplerate_linear,
  ]
  data = modes.flat_map { |m|
    MB::U.headline "Generating data for #{m.inspect}"

    $d1 = d1 = MB::M.select_zero_crossings(
      freq.hz.at(1).at_rate(from_rate)
        .resample(to_rate, mode: m)
        .sample(samples),
      nil
    )
    $d2 = d2 = MB::M.select_zero_crossings(
      freq.hz.at(1).at_rate(from_rate)
        .resample(to_rate, mode: m)
        .multi_sample(multi_samples, multi_count),
      nil
    )

    dlength = [d1.length, d2.length].min
    d1 = d1[0...dlength]
    d2 = d2[0...dlength]

    delta = d2.not_inplace! - d1.not_inplace!
    [
      ["#{m} large", d1],
      ["#{m} small", d2],
      ["#{m} diff", delta],
    ]
  }.to_h

  puts MB::U.highlight({
    graphical: graphical,
    spectrum: spectrum,
    samples: samples,
    from_rate: from_rate,
    to_rate: to_rate,
    freq: freq,
    multi_samples: multi_samples,
    multi_count: multi_count,
  })

  data.each do |name, data|
    MB::Sound.write("tmp/#{"#{$0}_#{name}".gsub(/[^A-Za-z0-9-]+/, '_')}.flac", data, sample_rate: to_rate, overwrite: true)
  end

  loop do
    if spectrum
      MB::Sound.mag_phase(
        data,
        graphical: graphical,
        freq_samples: samples
      )
    else
      MB::Sound.time_freq(
        data,
        graphical: graphical,
        time_samples: time_samples,
        freq_samples: samples,
        columns: 4
      )
    end

    sleep 2

    if pry_next
      binding.pry
      pry_next = false
    end

    # Loop in graphical mode to allow window resizing (TODO: figure out why
    # gnuplot doesn't resize plots when the window is resized)
    break unless graphical
  end
}

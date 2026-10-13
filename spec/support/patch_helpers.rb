# Helpers for specs of bin/synths/ patches (the persona panel's voices and
# their presets): MIDI note lists as Streams, and graphs rendered to arrays.
module PatchHelpers
  # A MIDI::Stream of notes: [note number, on seconds, off seconds,
  # velocity 0..1 (0.8 if left out)] each.
  def note_stream(*notes)
    events = notes.flat_map { |n, on, off, vel|
      [MB::Sound::MIDI::Event.note_on(n, vel || 0.8, time: on.to_r), MB::Sound::MIDI::Event.note_off(n, time: off.to_r)]
    }
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
  end

  # The output nodes of +graph+ (a node, a multi-output node, or a
  # Channels bundle).
  def patch_outputs(graph)
    return graph.to_a if graph.is_a?(MB::Sound::GraphNode::Channels)
    return graph.outputs if graph.respond_to?(:outputs) && graph.outputs.length > 1

    [graph]
  end

  # Renders +seconds+ of +graph+ in +buffer+-sample buffers, sampling every
  # output in turn.  Returns an Array of SFloat channels (shorter if the
  # graph ends).
  def render_patch(graph, seconds, buffer: 800)
    outs = patch_outputs(graph)
    data = outs.map { [] }
    (seconds * 48000 / buffer).ceil.times do
      bufs = outs.map { |o| o.sample(buffer) }
      break if bufs.any?(&:nil?)

      bufs.each_with_index { |b, i| data[i] << b.dup }
    end
    data.map { |c| c.empty? ? Numo::SFloat[] : Numo::SFloat.cast(c.reduce(:concatenate)) }
  end

  # Samples of +data+ (an SFloat) from +from+ to +to+ seconds.
  def seconds(data, from, to)
    data[(from * 48000).round...[(to * 48000).round, data.length].min]
  end

  # RMS level of +data+ in dB.
  def rms_db(data)
    10 * Math.log10((Numo::DFloat.cast(data)**2).mean + 1e-30)
  end

  # Peak level of +data+ in dB.
  def peak_db(data)
    20 * Math.log10(data.abs.max + 1e-30)
  end

  # The fraction of +data+'s power between +lo+ and +hi+ Hz.
  def band_share(data, lo, hi)
    x = Numo::DFloat.cast(data)
    s = Numo::Pocketfft.rfft(x).abs**2
    f = Numo::DFloat.new(s.length).seq * (48000.0 / x.length)
    s[(f >= lo) & (f < hi)].sum / s.sum
  end

  # The frequency in Hz of the strongest spectral peak of +data+ between
  # +lo+ and +hi+ Hz.
  def peak_hz(data, lo, hi)
    x = Numo::DFloat.cast(data) * (0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(data.length).seq * (2 * Math::PI / data.length)))
    s = Numo::Pocketfft.rfft(x).abs
    f = Numo::DFloat.new(s.length).seq * (48000.0 / x.length)
    mask = (f >= lo) & (f < hi)
    idx = mask.where
    f[idx[s[idx].max_index]]
  end
end

RSpec.configure do |c|
  c.include PatchHelpers
end

#!/usr/bin/env ruby
# Renders a gallery of channel mixing test sounds, one file per case, for
# null tests of channel mixing changes (see bin/null_test.rb): mono panning,
# stereo balance, width, mono mixdown, mid/side, swapping, matrix mixing,
# with fixed values and moving (graph node) values, and a reverb that mixes
# its channels with matrices.
#
# When the channel mixing API changes, each case is rewritten in the new API
# to describe the same sound, and the null test compares the renders.
#
# Usage: $0 [options] output_directory
#
# Examples:
#     $0 /tmp/channels                   # every case
#     $0 --only pan /tmp/channels        # cases whose names contain pan
#     $0 --list                          # case names

require 'bundler/setup'
require 'mb-sound'

def mono_source
  330.hz.triangle.at(0.5)
end

def stereo_source
  MB::Sound.stereo(220.hz.ramp.at(0.4), 331.hz.triangle.at(0.4))
end

# Case name => lambda returning a node, a bundle, or an Array of nodes
CASES = {
  pan_center: -> { mono_source.pan(0) },
  pan_static: -> { mono_source.pan(-0.3) },
  pan_hard_right: -> { mono_source.pan(1) },
  pan_lfo: -> { mono_source.pan(3.hz.lfo) },
  balance_static: -> { stereo_source.pan(0.4) },
  balance_lfo: -> { stereo_source.pan(2.hz.lfo) },
  width_wide: -> { stereo_source.width(1.5) },
  width_mono: -> { stereo_source.width(0) },
  width_node: -> { stereo_source.width(0.5.hz.lfo.at(0..2)) },
  mono_stereo: -> { stereo_source.mono },
  mono_three: -> { MB::Sound.channels(220.hz.ramp.at(0.4), 331.hz.triangle.at(0.4), 440.hz.sine.at(0.4)).mono },
  mid_side: -> { stereo_source.mid_side },
  mid_side_round_trip: -> { stereo_source.mid_side.from_mid_side },
  swap: -> { stereo_source.swap },
  matrix_2_to_3: -> {
    l, r = stereo_source.to_a
    MB::Sound::GraphNode::ChannelMixer::Matrix.new([l, r], matrix: [[1, 0.5], [0.25, -1], [0.3, 0.3]]).outputs
  },
  reverb_hall_stereo: -> { stereo_source.reverb(:hall) },
  place_rear_left: -> { mono_source.place(x: -1, y: -1) },
  place_side: -> { mono_source.place(x: 0.3, y: 0) },
  place_circling: -> { mono_source.place(x: 2.hz.lfo, y: 2.hz.lfo.with_phase(Math::PI / 2)) },
  place_complex: -> { 330.hz.complex_ramp.at(0.3).place(x: -0.5, y: 0.5).map(&:real) },
}

MB::Sound.script(
  args: 0..1,
  seconds: [1.0, '-s', 'Length of each case in seconds', 0.01..],
  only: [nil, String, 'Comma-separated substrings; render only matching cases'],
  list: [false, '-l', 'List case names and exit'],
) { |(outdir), p|
  if p.list
    puts CASES.keys
    next
  end
  abort 'Give an output directory (see --help)' unless outdir

  names = CASES.keys
  names = names.select { |n| p.only.split(',').any? { |o| n.to_s.include?(o) } } if p.only

  FileUtils.mkdir_p(outdir)
  names.each do |name|
    MB::Sound.rewind
    sound = CASES.fetch(name).call
    sound = sound.outputs if sound.respond_to?(:outputs) && sound.channel_count > 1
    sound = sound.to_a if sound.respond_to?(:to_a) && !sound.is_a?(MB::Sound::GraphNode)
    channels = sound.is_a?(Array) ? sound.length : 1
    path = File.join(outdir, "#{name}.flac")
    MB::Sound.render(path, sound, seconds: p.seconds, bpm: 120, channels: channels, gain: 1, overwrite: true)
    puts "#{name}: #{path}"
  end
}

# Read-ahead sweep (fix-bus-resample-1, 2026-11-08): chains whose nodes read
# their sources ahead of their output (resamplers in every mode, a
# BufferAdapter, an oversample region, a dry path beside a resampled one),
# each played on a track, as a bus chain, as a master chain, and after a bus
# tap, at several buffer sizes (spec/lib/mb/sound/graph_node/read_ahead_spec.rb).
# On a track a chain reads its sources ahead and isn't late; span-fed
# sources (a chain's MixSource, a bus tap) can't give frames past the
# span, so there the chain hears its input GraphNode::ReadAhead frames late:
# the relation is "the track's output, that many frames later", within
# -80 dB of the peak, and the latency doesn't depend on the buffer size.
# Before the fix a MixSource handed every whole-buffer read the same buffer
# and a tap read zeros past the span: the first buffer played up to three
# times and the chain came out two buffers late (1600 frames at 800, 734
# at 367).
#
# A new node class with #read_ahead fails the guard until a chain here
# builds it.
module ReadAheadSweep
  # name => block building a chain from a mono node.
  CHAINS = {
    best_pair: ->(s) { s.resample(96000).resample(48000) },
    fastest_pair: ->(s) { s.resample(96000, mode: :libsamplerate_fastest).resample(48000, mode: :libsamplerate_fastest) },
    linear_pair: ->(s) { s.resample(96000, mode: :libsamplerate_linear).resample(48000, mode: :libsamplerate_linear) },
    zoh_pair: ->(s) { s.resample(96000, mode: :libsamplerate_zoh).resample(48000, mode: :libsamplerate_zoh) },
    ruby_linear_pair: ->(s) { s.resample(96000, mode: :ruby_linear).resample(48000, mode: :ruby_linear) },
    ruby_zoh_pair: ->(s) { s.resample(96000, mode: :ruby_zoh).resample(48000, mode: :ruby_zoh) },
    down_up_44k: ->(s) { s.resample(44100).resample(48000) },
    filter_between: ->(s) { s.resample(96000).filter(:lowpass, cutoff: 20000.0, quality: 0.7).resample(48000) },
    oversampled_region: ->(s) { s.resample(96000).lp4(9000).oversample(2).resample(48000) },
    buffer_adapter: ->(s) { s.with_buffer(300) },
    dry_beside: ->(s) { s * 0.5 + s.resample(96000).resample(48000) * 0.5 },
  }.freeze

  # Where a chain plays.
  CONTEXTS = %i[track bus master tap].freeze

  module_function

  # A seeded noise burst with silence around it (frames at 48 kHz).
  def signal(frames = 9600)
    rng = Random.new(1108)
    d = Numo::SFloat.zeros(frames)
    (1000...(frames - 3000)).each { |i| d[i] = rng.rand * 2 - 1 }
    d
  end

  # Renders +chain+ (a CHAINS key) in +context+ for +frames+ frames in
  # buffers of +sizes+ (cycled): [output (mono SFloat), latency in frames
  # the Session declares (0 on a track)].
  def render(chain, context, sizes, frames: 14400)
    build = CHAINS.fetch(chain)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                               channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
    input = -> { MB::Sound::ArrayInput.new(data: [signal], sample_rate: 48000) }
    latency = nil
    MB::Sound::Session.with_context(session: s) do
      case context
      when :track
        s.add(build.(input.()), name: :t)
        latency = -> { 0 }
      when :bus
        s.bus(:b) { |sig| build.(sig) }
        s.add(input.(), name: :t, to: :b)
        latency = -> { s.instance_variable_get(:@buses)[:b].chains.last.latency }
      when :master
        s.master { |sig| build.(sig) }
        s.add(input.(), name: :t)
        latency = -> { s.instance_variable_get(:@master_chains).last.latency }
      when :tap
        s.route(:src, trigger: true)
        s.add(input.(), name: :src)
        tap = MB::Sound::GraphNode::BusTap.new(:src, channels: 1)
        s.add(build.(tap.outputs[0]), name: :rd)
        latency = -> { tap.read_ahead }
      end
    end

    bufs = []
    left = frames
    sizes = sizes.cycle
    while left > 0
      n = [sizes.next, left].min
      bufs << s.process_buffer(n)[0].dup
      left -= n
    end
    [SpecBuffers.join(bufs), latency.()]
  ensure
    s&.close
  end

  # The node classes +chain+ builds.
  def classes(chain)
    root = CHAINS.fetch(chain).(MB::Sound::ArrayInput.new(data: [signal(100)], sample_rate: 48000))
    [root, *root.graph].map(&:class).uniq
  end

  # GraphNode classes with their own #read_ahead.
  def read_ahead_classes
    ObjectSpace.each_object(Class).select { |c|
      (c < MB::Sound::GraphNode) && c.method_defined?(:read_ahead) && c.instance_method(:read_ahead).owner == c
    }
  end
end

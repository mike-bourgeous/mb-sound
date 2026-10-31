# Check mode over the graph sweep (kernels-1): every GraphNode type in the
# sweep's small graphs, planned and unplanned, with every kernel in
# MB::Sound::Kernels' :check mode, so each C kernel the graphs reach runs
# beside its Ruby mirror on the same inputs and state and the two are
# compared (exactly, or within the entry's tolerance).  A mismatch raises
# Kernels::Mismatch naming the kernel and the first difference.
#
# The kernels the sweep doesn't reach are compared by their own specs;
# kernels_guard_spec.rb lists where (KernelsGuard::COMPARED_ELSEWHERE).
require_relative '../../../support/graph_sweep'
require_relative '../../../support/kernels_guard'
require 'mb/sound/ui'

# Scenes beyond the graph sweep that reach the other kernels (plots,
# sessions with buses, meters, dice, wavetable modes, ...), run in check
# mode too.  Each returns nothing in particular; a mismatch raises.
module KernelCheckExtras
  module_function

  def session
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1,
                           buffer_size: 128, realtime: false, raise_errors: true)
  end

  SCENES = {
    'a session with a bus, a send, a reader, and tails' => lambda do
      s = session
      s.bus(:half) { |sig| sig * 0.5 }
      s.add(220.hz.saw.at(0.3).until(300.samples), name: :x, send: { half: 0.5 })
      s.add(0.5.constant.duck(:half), name: :pad)
      12.times { s.process_buffer(128) }
    ensure
      s&.close
    end,
    'plots of every mark kind, decimated' => -> {
      wave = Numo::DFloat.new(5000).seq.map { |i| Math.sin(i * 0.01) }
      chart = MB::Sound::Plot.chart { line wave, label: 'a'; area wave.abs, label: 'b'; points [1, 3, 2], label: 'c' }
      MB::Sound::Plot::Text.render(chart, width: 60, height: 12, color: :none)
      MB::Sound::Plot::Text.render(MB::Sound::Plot.waveform(wave), width: 40, height: 8, color: :none)
    },
    'the master and bus meters' => -> {
      m = MB::Sound::UI::MasterMeter.new(2, 48000)
      buf = Numo::SFloat.new(800).rand(-1, 1)
      3.times { m.process([buf, buf]) }
      MB::Sound::Kernels.peak_sumsq(buf, 1.0)
      MB::Sound::Kernels.sum_squares(Numo::DFloat.cast(buf))
    },
    'dice' => -> {
      d = MB::Sound::Generative::Dice.new(3)
      [d.rand(:a, 2), d.rands(4), d.int(1..6, :b), d.pick({ a: 1, b: 2 }, :c), d[:x].state, MB::Sound::Generative::Dice.key(:x)]
    },
    'shape values, unison detune modes, and biquad steps' => -> {
      MB::Sound::Tone.value_at(:triangle, 0.3)
      [110.hz.unison(3, detune: 2.hz.lfo.at(0..0.3), detune_mode: :interp) { |p| p.saw },
       110.hz.unison(3, detune: 0.2.constant, detune_mode: :exact) { |p| p.saw }].each { |u| 3.times { u.sample(128) } }
      MB::Sound::Kernels.biquad(0.2, 0.1, 0.05, -0.3, 0.1, 0.5, 0.1, 0.0, 0.2, 0.1)
      MB::Sound::Kernels.biquad_complex(0.2, 0.1, 0.05, -0.3, 0.1, Complex(0.5, 0.1), 0.1, 0.0, 0.2, 0.1)
    },
    'wavetable sync, sample playback, and key-synced resets' => -> {
      samples = Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) }
      trig = MB::Sound.seq(MB::Sound::C4.n64, MB::Sound::E4.n64).loop.notes.trigger
      graphs = [
        220.hz.wavetable(:basic_norm, scan: 0.5).sync(110.hz.saw.fm(5.hz.lfo.at(20))),
        220.3.hz.wavetable(MB::Sound::Wavetable.from_samples(samples, mode: :sample, root: 200, loop: 1000...4000)),
        220.hz.wavetable(:basic_norm).reset(trig),
        220.hz.saw.reset(MB::Sound.seq(MB::Sound::C4.n64, MB::Sound::E4.n64).loop.notes.trigger), # (phase jump steps)
      ]
      graphs.each { |g| 16.times { g.sample(128) } } # (past the second note: resets after playing queue jump steps)
    },
    'smoothstep fills' => -> {
      MB::Sound::Kernels.smoothstep_buf(Numo::SFloat.zeros(16))
      MB::Sound::Kernels.smootherstep_buf(Numo::SFloat.zeros(16).inplace!)
    },
  }.freeze
end

RSpec.describe('kernel check mode over the graph sweep', :check_shared) do
  around(:each) do |example|
    old = MB::Sound::Plan.enabled
    example.run
  ensure
    MB::Sound::Plan.enabled = old
  end

  # Buffer sizes and counts: the everyday size, then (slow tier) one-sample
  # buffers over the edges and a long buffer.
  sizes = [[128, 3], *SlowTier.slow_tier([[7, 4], [800, 2]], keep: 0)]

  GraphSweep.factories.each do |name, factory|
    it "matches the C kernels' Ruby mirrors for #{name}, planned and unplanned" do
      [true, false].each do |planned|
        sizes.each do |size, buffers|
          MB::Sound::Plan.enabled = planned
          MB::Sound.seed(1)
          graph = MB::Sound::Kernels.with(:check) { factory.call(GraphSweep::Context.new) }
          MB::Sound::Plan.install(graph) if planned
          begin
            MB::Sound::Kernels.with(:check) { GraphSweep.run(graph, size, buffers) }
          rescue => e
            raise e.class, "#{name} (#{planned ? 'planned' : 'unplanned'}, #{size}-sample buffers): #{e.message}", e.backtrace
          end
        end
      end
    end
  end

  KernelCheckExtras::SCENES.each do |name, scene|
    it "matches the C kernels' Ruby mirrors for #{name}" do
      MB::Sound.seed(1)
      MB::Sound::Kernels.with(:check) { scene.call }
    end
  end

  it 'compares the kernels the sweep reaches, and every other kernel has a compare spec' do
    MB::Sound::Kernels.reset_checked
    KernelCheckExtras::SCENES.each_value { |scene| MB::Sound::Kernels.with(:check) { scene.call } }
    GraphSweep.factories.each do |_, factory|
      [true, false].each do |planned|
        MB::Sound::Plan.enabled = planned
        MB::Sound.seed(1)
        graph = MB::Sound::Kernels.with(:check) { factory.call(GraphSweep::Context.new) }
        MB::Sound::Plan.install(graph) if planned
        MB::Sound::Kernels.with(:check) { GraphSweep.run(graph, 128, 1) }
      end
    end
    checked = MB::Sound::Kernels.checked.keys | MB::Sound::Kernels.declined.keys | MB::Sound::Kernels.nested.keys
    expect(checked.length).to be > 40

    missing = KernelsGuard.checkable_entries.map(&:name) - checked - KernelsGuard::COMPARED_ELSEWHERE.keys
    expect(missing).to eq([]), "kernels neither the check-mode sweep reaches nor COMPARED_ELSEWHERE lists: #{missing.join(', ')}"

    # (an entry listed as compared elsewhere that the sweep now reaches is
    # fine: the list says where else it is compared)
  end
end

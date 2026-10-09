# "Memcheck light": every GraphNode type, every filter type, in small
# graphs with modulated inputs, MIDI events, stereo bundles, and feedback
# loops, run planned and unplanned (MB::Sound::Plan) at buffer sizes 1, 128,
# and 800.  In the normal suite it checks for exceptions and non-finite
# output; under Valgrind (every `rake memcheck:changed` run includes it, see
# MemcheckSelection::ALWAYS) it reaches C paths that the per-extension specs
# may not combine.
#
# FACTORIES builds one representative graph per entry from a context with
# modulated sources and short clips.  Filter entries are generated from the
# filters' own type lists (Filter::SVF::FILTER_TYPES, Cookbook::FILTER_TYPES,
# FourPole::MODES / DRIVE_MODES), so new types are swept automatically.
# Filters are plan ops (SVF, cookbook biquad, four-pole; 2026-10-10), so
# the planned variant covers their fused regions; an example checks every
# filter entry is fused.
#
# The guard records every GraphNode, multi-output, and Filter class
# constructed while building the factories, and requires every such class
# in lib/ to be built by some factory or listed in EXEMPT with a reason.
require 'set'

module GraphSweep
  SIZES = { 1 => 40, 128 => 6, 800 => 3 }.freeze # buffer size => buffers

  # Inputs shared by the factories (a new context per graph).
  class Context
    def s
      MB::Sound
    end

    # An audio-rate source (a band-limited saw)
    def sig(f = 110)
      f.hz.ramp.at(0.5)
    end

    # A modulated control input from lo to hi
    def mod(lo, hi, rate = 7)
      rate.hz.lfo.at(lo..hi)
    end

    def stereo_sig
      s.stereo(sig(110), sig(165))
    end

    # A short clip whose first note starts at sample 0 (note edges inside
    # the first buffers at every size)
    def clip
      s.seq(s::C4.n128, s::E4.n128, s::G4.n64, s::C5.n128).loop
    end

    def notes
      clip.notes
    end

    def trigger
      notes.trigger
    end
  end

  # Writes a source's buffers into a MixSource and samples a chain built on
  # it, as Session's master effects do.
  class MixFeeder
    include MB::Sound::GraphNode
    include MB::Sound::GraphNode::SampleRateHelper

    def initialize(source)
      @source = source
      @mix = MB::Sound::GraphNode::MixSource.new(channels: 2, sample_rate: 48000)
      @chain = yield(MB::Sound::GraphNode::Channels.new(@mix.outputs))
      @sample_rate = 48000.0
    end

    def sources
      { source: @source }
    end

    def sample(count)
      @mix.write(@source.outputs.map { |o| o.sample(count) })
      @chain.sample(count)
    end
  end

  def self.svf_factories
    MB::Sound::Filter::SVF::FILTER_TYPES.flat_map { |t|
      gain = MB::Sound::Filter::SVF::GAIN_TYPES.include?(t)
      [
        ["filter(#{t.inspect}) constant", ->(c) { c.sig.filter(t, cutoff: 800, quality: 2, gain: gain ? 2.0 : nil) }],
        ["filter(#{t.inspect}) modulated", ->(c) { c.sig.filter(t, cutoff: c.mod(200, 4000), quality: c.mod(0.5, 6, 3), gain: gain ? c.mod(0.5, 2, 5) : nil) }],
        ["feedback filter(#{t.inspect}) constant", ->(c) {
          c.sig.feedback { |fb, input| input + fb.delay(40.samples).filter(t, cutoff: 1200, quality: 1.5, gain: gain ? 1.5 : nil) * 0.4 }
        }],
        ["feedback filter(#{t.inspect}) modulated", ->(c) {
          c.sig.feedback { |fb, input|
            input + fb.delay(c.mod(20, 60, 2).samples).filter(t, cutoff: c.mod(300, 3000), quality: c.mod(0.6, 3, 4), gain: gain ? c.mod(0.5, 1.5) : nil).softclip * 0.5
          }
        }],
      ]
    }
  end

  def self.biquad_factories
    MB::Sound::Filter::Cookbook::FILTER_TYPES.flat_map { |t|
      gain = MB::Sound::Filter::SVF::GAIN_TYPES.include?(t)
      [
        ["filter(#{t.inspect}, structure: :biquad) constant", ->(c) { c.sig.filter(t, cutoff: 800, quality: 2, gain: gain ? 2.0 : nil, structure: :biquad) }],
        ["filter(#{t.inspect}, structure: :biquad) modulated", ->(c) { c.sig.filter(t, cutoff: c.mod(200, 4000), quality: c.mod(0.5, 6, 3), gain: gain ? 2.0 : nil, structure: :biquad) }],
      ]
    }
  end

  def self.four_pole_factories
    fp = MB::Sound::Filter::FourPole
    modes = fp::MODES.keys.flat_map { |m|
      [
        ["lp4(mode: #{m.inspect}) constant", ->(c) { c.sig.lp4(900, resonance: 0.6, mode: m) }],
        ["lp4(mode: #{m.inspect}) modulated", ->(c) { c.sig.lp4(c.mod(150, 5000), resonance: c.mod(0, 1, 3), mode: m) }],
        ["lp4(mode: #{m.inspect}) self-oscillating", ->(c) { c.sig.lp4(c.mod(300, 2000), resonance: 0.95, mode: m, self_oscillate: true) }],
      ]
    }
    # Every valid mode x drive mode x clip combination (invalid ones raise
    # ArgumentError when built, e.g. clip: without drive_mode: :feedback)
    drives = fp::MODES.keys.product(fp::DRIVE_MODES.keys, fp::CLIPS.keys).filter_map { |m, d, clip|
      begin
        fp.new(mode: m, drive: 2, drive_mode: d, clip: clip)
      rescue ArgumentError
        next
      end
      ["lp4(mode: #{m.inspect}, drive_mode: #{d.inspect}, clip: #{clip.inspect})", ->(c) { c.sig.lp4(c.mod(200, 3000), resonance: 0.8, mode: m, drive: 2, drive_mode: d, clip: clip) }]
    }
    others = [
      ['lp4 quality: node', ->(c) { c.sig.lp4(1000, quality: c.mod(0.7, 8)) }],
      ['lp4 linear curve', ->(c) { c.sig.lp4(1000, resonance: 0.5, resonance_curve: :linear) }],
      ['diode unnormalized', ->(c) { c.sig.diode(c.mod(200, 3000), resonance: 0.5, normalize: false) }],
    ]
    modes + drives + others
  end

  # Filter objects through node.filter(obj) (SampleWrapper)
  def self.filter_object_factories
    f = MB::Sound::Filter
    [
      ['Butterworth', ->(c) { c.sig.filter(f::Butterworth.new(:lowpass, 4, 48000, 1200)) }],
      ['Butterworth highpass', ->(c) { c.sig.filter(f::Butterworth.new(:highpass, 3, 48000, 300)) }],
      ['FIR', ->(c) { c.sig.filter(f::FIR.new({ 0 => 1, 2000 => 1, 3000 => 0, 24000 => 0 }, filter_length: 64)) }],
      ['FirstOrder', ->(c) { c.sig.filter(f::FirstOrder.new(:lowpass, 48000, 500)) }],
      ['FirstOrder highpass', ->(c) { c.sig.filter(f::FirstOrder.new(:highpass, 48000, 500)) }],
      ['HilbertIIR', ->(c) { c.sig.filter(f::HilbertIIR.new) }],
      ['Gain', ->(c) { c.sig.filter(f::Gain.new(0.5, sample_rate: 48000)) }],
      ['LinearFollower', ->(c) { c.sig.filter(f::LinearFollower.new(sample_rate: 48000, max_rise: 100, max_fall: 50, absolute: true)) }],
      ['SimpleEnvelopeFollower', ->(c) { c.sig.filter(f::SimpleEnvelopeFollower.new(sample_rate: 48000)) }],
      ['Smoothstep', ->(c) { c.sig.filter(f::Smoothstep.new(sample_rate: 48000, samples: 40)) }],
      ['Biquad', ->(c) { c.sig.filter(f::Biquad.new(0.2, 0.4, 0.2, -0.3, 0.1, sample_rate: 48000)) }],
      ['Cookbook object', ->(c) { c.sig.filter(f::Cookbook.new(:peak, 48000, 1000, quality: 2, db_gain: 6)) }],
      ['Cookbook object as biquad', ->(c) { c.sig.filter(f::Cookbook.new(:lowpass, 48000, 1000, quality: 2), structure: :biquad) }],
      ['SVF object', ->(c) { c.sig.filter(f::SVF.new(:notch, 48000, 1000, quality: 2)) }],
      ['FilterChain', ->(c) { c.sig.filter(f::FilterChain.new(f::FirstOrder.new(:lowpass, 48000, 2000), f::Cookbook.new(:highpass, 48000, 100, quality: 0.7))) }],
      ['FilterSum', ->(c) { c.sig.filter(f::FilterSum.new(f::FirstOrder.new(:lowpass, 48000, 400), f::FirstOrder.new(:highpass, 48000, 4000))) }],
      ['Filter::Delay object', ->(c) { c.sig.filter(f::Delay.new(delay: 0.003, sample_rate: 48000, feedback: 0.5, wet: 0.5, dry: 1)) }],
    ]
  end

  def self.node_factories
    [
      # Oscillators and Tone options
      ['sine', ->(c) { 440.hz.sine }],
      ['naive shapes', ->(c) { 220.hz.asquare + 330.hz.atriangle + 110.hz.aramp }],
      ['band-limited shapes', ->(c) { 220.hz.square + 330.hz.triangle.pwm(c.mod(0.1, 0.9)) + 110.hz.ramp.fm(c.mod(-50, 50, 3)) }],
      ['complex shapes', ->(c) { (220.hz.complex_ramp.pm(c.mod(-0.5, 0.5, 30)) + 220.hz.complex_square.pwm(0.3) + 330.hz.complex_triangle).real }],
      ['phasor', ->(c) { 100.hz.phasor }],
      ['sync and softsync', ->(c) { 200.hz.ramp.sync(ratio: c.mod(1.2, 3)) + 150.hz.square.softsync(ratio: 2.3) }],
      ['sync to master tone', ->(c) { 300.hz.triangle.sync(97.hz.phasor) }],
      ['feedback sine', ->(c) { 220.hz.sine.fm_feedback(c.mod(0, 2.5), gain: c.mod(0.3, 1, 2)) }],
      ['tone gain node', ->(c) { 330.hz.ramp.gain(c.mod(0, 1)) }],
      ['tone reset clean', ->(c) { 180.hz.ramp.reset(c.trigger, clean: true) + 90.hz.square.reset(c.trigger, to: :random) }],
      ['noise', ->(c) { c.s.noise(seed: 3) + 220.hz.ramp.noise(0.3, seed: 4) }],
      ['wavetable', ->(c) { 220.hz.wavetable(MB::Sound::Wavetable[:basic], scan: c.mod(0, 1, 2)) }],
      ['wavetable sync pwm', ->(c) { 220.hz.wavetable(MB::Sound::Wavetable[:saw]).sync(ratio: 1.7).pwm(0.3) }],
      ['wavetable sample mode reset', ->(c) {
        t = MB::Sound::Wavetable.from_samples(Numo::SFloat.new(4000).rand(-1, 1), mode: :sample, root: 440) rescue MB::Sound::Wavetable[:saw]
        220.hz.wavetable(t).reset(c.trigger)
      }],
      ['phase_table and waveshape', ->(c) { 50.hz.phasor.phase_table(MB::Sound::Wavetable[:saw], scan: 0.3) + c.sig.waveshape(MB::Sound::Wavetable[:sine]) }],
      ['harmonics (HarmonicTable)', ->(c) { 110.hz.harmonics([1, c.mod(0, 1), 0.3, 0.2], update: 64) }],
      ['unison', ->(c) { 220.hz.unison(5, detune: c.mod(0.05, 0.3, 1)) { |p, _i| p.ramp } }],
      ['unison spread stereo', ->(c) { 220.hz.unison(4, spread: 1) { |p, _i| p.square } }],
      ['swarm', ->(c) { c.notes.hz.swarm(4, scatter: 1.oct) { |p, _i| p.ramp } }],
      ['transpose node (SemitoneShift)', ->(c) { 220.hz.transpose(c.mod(-12, 12, 2)).ramp }],
      ['vibrato', ->(c) { 220.hz.vibrato(5, depth: 0.5).ramp }],
      ['tempo tone (TempoNode)', ->(c) { 1.beat.hz.ramp + 2.bars.lfo.square }],
      ['tempo delay', ->(c) { c.sig.delay(1.n32) }],

      # Arithmetic and routing
      ['arithmetic', ->(c) { (c.sig * c.mod(0, 1) + 0.1.constant - c.sig(55) / 2.constant.+(c.mod(0, 1))) }],
      ['power, abs, rounding, logs', ->(c) { (c.mod(0.1, 2) ** 2.constant) + c.sig.aabs + c.sig.abs + (c.mod(0.5, 3).log + c.mod(1, 4).log2).floor + c.sig.round + c.sig.ceil }],
      ['complex parts', ->(c) { c.sig.real + 200.hz.complex_sine.imag + 200.hz.complex_sine.arg }],
      ['constant smooth', ->(c) { 0.5.constant(smoothing: 0.01) + c.sig }],
      ['proc', ->(c) { c.sig.proc { |buf| buf * 0.5 } }],
      ['tee and branches', ->(c) { t = c.sig; t.softclip + t.delay(10.samples) + t }],
      ['with_buffer (BufferAdapter)', ->(c) { c.sig.with_buffer(37.samples) }],
      ['until and and_then (TimeLimit, NodeSequence, Silence)', ->(c) { c.sig.until(0.002).and_then(c.s.silence(0.001), c.sig(220)) }],
      ['ringdown', ->(c) { c.sig.until(0.003).ringdown }],
      ['sample_hold', ->(c) { c.sig.sample_hold(c.trigger) + c.mod(0, 1).sah(range: -1..1) }],
      ['ArrayInput', ->(c) { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(3000).rand(-1, 1)], repeat: 2) }],
      ['NullInput', ->(c) { MB::Sound::NullInput.new(sample_rate: 48000, channels: 2) }],

      # Shapers
      ['shapers', ->(c) { c.sig.softclip + c.sig.clip(-0.3, 0.3) + c.sig.quantize(0.1) + c.sig.asoftclip + c.sig.aclip(-0.5, 0.2) + c.sig.aquantize(0.2) }],
      ['ease (CurveShaper)', ->(c) { c.sig.ease(:elastic) + c.sig.aease(:smoothstep) + c.sig.ease(:bounce, edges: :mirror) }],
      ['Quantize node', ->(c) { c.sig.quantize(c.mod(0.01, 0.2)) }],

      # Delays and reverbs
      ['delay modulated', ->(c) { c.sig.delay(c.mod(0.001, 0.004, 3), feedback: c.mod(0, 0.6), wet: 0.5, dry: 0.5) }],
      ['delay cubic and linear', ->(c) { c.sig.delay(c.mod(0.001, 0.003), interpolation: :cubic) + c.sig.delay(0.0021, interpolation: :linear) }],
      ['multitap', ->(c) { c.sig.multitap(0.001, c.mod(0.002, 0.003), 37.samples).mixdown }],
      ['reverb', ->(c) { c.stereo_sig.reverb(:room) }],
      ['reverb room-size factory', ->(c) { c.sig.reverb(room_size: 0.3, decay: 0.5, damping: 0.5) + c.sig.reverb(room_size: 0.2, decay: 0.3, output_channels: 2).mixdown }],
      ['reverb modulation and loop processing', ->(c) {
        c.stereo_sig.reverb(:room, mod: :lush, diffusion_mod: :subtle, lowpass: 4000, highpass: 80, drive: 2, crush: 10, shimmer: 0.3).mixdown
      }],
      ['reverb parameter nodes', ->(c) {
        c.sig.reverb(room_size: 0.2, decay: 0.4, mod: { depth: c.mod(0, 0.001), rate: c.mod(0.2, 2) }, lowpass: c.mod(500, 8000), freeze: c.mod(0, 1), stretch: c.mod(0.8, 1.2), shimmer: c.mod(0, 1), drive: c.mod(0, 3), drive_mode: :fold)
      }],
      ['chorus', ->(c) { c.stereo_sig.chorus(:juno2) }],
      ['chorus with hiss (HissGate)', ->(c) { c.sig.chorus(:juno1, hiss: -60) }],
      ['ping (Resonator)', ->(c) { c.trigger.ping(c.mod(200, 2000), decay: 0.05) }],

      # Feedback loops
      ['feedback one-pole', ->(c) { c.sig.feedback { |fb, input| input + (fb - input) * 0.9 } }],
      ['feedback Karplus-Strong', ->(c) {
        c.trigger.feedback { |fb, input| input + fb.delay(c.mod(0.002, 0.004, 1)).filter(:lowpass, cutoff: 3000) * 0.95 }
      }],
      ['feedback shapers and arithmetic', ->(c) {
        c.sig.feedback { |fb, input| input + (fb.delay(23.samples, interpolation: :cubic) * c.mod(0.2, 0.7)).softclip.quantize(0.01).clip(-1, 1).abs / 2.constant ** 1.constant }
      }],
      ['feedback stereo', ->(c) { c.stereo_sig.feedback { |fb, input| input + fb.delay(0.001) * 0.5 } }],

      # Multichannel
      ['pan, balance, width', ->(c) { c.sig.pan(c.mod(-1, 1)).width(c.mod(0, 2)) + c.stereo_sig.balance(0.3) }],
      ['mid_side, swap, mono', ->(c) { c.stereo_sig.mid_side.from_mid_side.swap.mono }],
      ['matrix and place', ->(c) { c.stereo_sig.matrix([[1, 0.5], [0.2, c.mod(0, 1)], [0.3, 0.3]]) + c.sig.place(x: c.mod(-1, 1), y: 0.5).channels(0, 1).mixdown rescue c.stereo_sig.matrix([[1, 0.5], [0.2, 1]]) }],
      ['complex matrix (Analytic)', ->(c) { c.stereo_sig.matrix([[1, 1i], [0.5, -1i]]) }],
      ['stereo filter, lp4, softclip', ->(c) { c.stereo_sig.filter(:lowpass, cutoff: c.s.channels(500, 900), quality: 2).lp4(1000, resonance: 0.5).softclip }],
      ['left/right', ->(c) { c.stereo_sig.left + c.stereo_sig.right }],
      ['loudness_meter', ->(c) { c.stereo_sig.loudness_meter }],
      ['resample and oversample', ->(c) { c.sig.resample(44100) + c.sig.oversample(2) { |n| n.softclip } }],
      ['MixSource (master chain input)', ->(c) { MixFeeder.new(c.stereo_sig) { |mix| mix.softclip.filter(:highpass, cutoff: 50).mixdown } }],

      # Envelopes
      ['adsr', ->(c) { c.sig.adsr(0.001, 0.002, 0.5, 0.003) }],
      ['envelope gated', ->(c) { c.s.adsr(0.001, 0.002, 0.5, 0.003, gate: c.notes.gate) * c.sig }],
      ['envelope segments loop', ->(c) { c.s.env([[1, 0.001], [0.3, 0.002], [0.6, 0.001], [0, 0.002]], release_at: 3, loop: 1, gate: c.notes.gate) }],
      ['sq80_env (TimeScale)', ->(c) { c.notes.sq80_env(t1: 5, t2: 10, t3: 8, t4: 12, t1v: 20, tk: 30, lv: 40) * c.sig }],

      # MIDI (Notes nodes, Synth)
      ['notes nodes', ->(c) {
        n = c.notes
        n.gate + n.trigger + n.number / 100.constant + n.velocity + n.lift + n.choke + n.freq / 1000.constant +
          n.bend + n.pressure + n.aftertouch + n.poly_pressure + n.mod + n.key_trigger + n.accent + n.cc(74)
      }],
      ['notes envelopes and voice helpers', ->(c) {
        n = c.notes
        n.hz.ramp.lp4(n.cutoff(800, env: n.filt_env), resonance: n.reso(0.5)) * n.amp_env + n.hz.glide(0.01).square.filter(:lowpass, cutoff: 900, quality: n.quality(2)) * n.fm_env(gm: true)
      }],
      ['notes lfo and fade-in', ->(c) { c.notes.lfo(5, delay: 0.002) + c.notes.lfo(3, shape: :noise) + c.notes.hz.vibrato(5).sine }],
      ['synth', ->(c) { c.clip.synth(voices: 2) { |v, _i| v.hz.ramp.filter(:lowpass, cutoff: v.cutoff(1000)) * v.amp_env(0.001, 0.002, 0.5, 0.002) } }],
      ['synth stereo voices', ->(c) { c.clip.synth(voices: 2) { |v, _i| (v.hz.ramp * v.env).pan(0.3) } }],
      ['drums (Kit, Voice)', ->(c) { c.s.tr808(c.s.grid(16, bd: 'x.x.', snare: '.x..', hat: 'xxxx')) }],
    ]
  end

  def self.factories
    node_factories + svf_factories + biquad_factories + four_pole_factories + filter_object_factories
  end

  # Node classes the sweep doesn't build, with reasons.
  EXEMPT = {
    'MB::Sound::DeviceInput' => 'sound card input; device_input_spec runs it',
    'MB::Sound::FFMPEGInput' => 'file input through ffmpeg (not traced by Valgrind)',
    'MB::Sound::IOInput' => 'base of FFMPEGInput',
    'MB::Sound::InputBufferWrapper' => 'wraps an input stream for window readers, not a graph node in use',
    'MB::Sound::OutputBufferWrapper' => 'wraps an output stream for window writers',
    'MB::Sound::GraphNode::DataShuffler' => 'test/debug helper with no DSL entry point',
    'MB::Sound::Filter::FilterBank' => 'parallel filters over Arrays of plain data, not used in graphs',
  }.freeze

  # Samples every output of +graph+ in turn, +count+ samples per buffer, for
  # +buffers+ buffers; returns the number of finite-checked buffers.
  def self.run(graph, count, buffers)
    outs = graph.respond_to?(:outputs) ? graph.outputs.to_a : [graph]
    live = outs.dup
    checked = 0
    buffers.times do
      live.select! do |o|
        buf = o.sample(count)
        next false if buf.nil?

        data = buf.is_a?(Numo::NArray) ? buf : Numo::NArray.cast(buf)
        data = Numo::DFloat.cast(data.real).concatenate(Numo::DFloat.cast(data.imag)) if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
        raise "non-finite output from #{o} (#{data.isfinite.count_false} of #{data.length})" unless data.isfinite.all?

        checked += 1
        true
      end
      break if live.empty?
    end
    checked
  end
end

RSpec.describe('graph sweep (memcheck light)', :check_shared) do
  around(:each) do |example|
    old = MB::Sound::Plan.enabled
    example.run
  ensure
    MB::Sound::Plan.enabled = old
  end

  names = GraphSweep.factories.map(&:first)
  it 'has unique factory names' do
    expect(names.length).to eq(names.uniq.length)
  end

  GraphSweep.factories.each do |name, factory|
    it "runs #{name} planned and unplanned at every buffer size" do
      [true, false].each do |planned|
        GraphSweep::SIZES.each do |size, buffers|
          MB::Sound::Plan.enabled = planned
          MB::Sound.seed(1)
          graph = factory.call(GraphSweep::Context.new)
          MB::Sound::Plan.install(graph) if planned
          begin
            GraphSweep.run(graph, size, buffers)
          rescue => e
            raise e.class, "#{name} (#{planned ? 'planned' : 'unplanned'}, #{size}-sample buffers): #{e.message}", e.backtrace
          end
        end
      end
    end
  end

  # Filters are plan ops (2026-10-10): the planned variant above runs them
  # fused.  This keeps it that way: every SVF, cookbook biquad, and
  # four-pole entry (outside feedback loops) has its filter node in a
  # region when planned.
  it 'fuses every filter entry in the planned variant' do
    MB::Sound::Plan.enabled = true
    filters = GraphSweep.factories.select { |name, _| name.start_with?('filter(:', 'lp4', 'diode') }
    expect(filters.length).to be > 40
    unfused = filters.reject { |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      inst = MB::Sound::Plan.install(graph)
      members = inst ? inst.regions.flat_map(&:members) : []
      members.any? { |m| m.is_a?(MB::Sound::Filter::SampleWrapper) || m.is_a?(MB::Sound::GraphNode::FourPole) }
    }.map(&:first)
    expect(unfused).to eq([])
  end

  describe 'coverage guard' do
    def library_classes
      Dir[File.expand_path('../../../../lib/mb/sound/**/*.rb', __dir__)].sort.each { |f| require f }
      g = MB::Sound::GraphNode
      ObjectSpace.each_object(Class).select { |c|
        c.name&.start_with?('MB::Sound::') && (c.include?(g) || c.include?(g::MultiOutput) || c <= MB::Sound::Filter)
      }.reject { |c| c.name.start_with?('MB::Sound::Plan') || c == MB::Sound::Filter }
    end

    it 'builds every GraphNode, multi-output, and Filter class, or lists it in EXEMPT' do
      built = Set.new
      # Ruby 4's opt_new skips the Class#new call event, so watch initialize
      tp = TracePoint.new(:call, :c_call) { |t| built << t.self.class if t.method_id == :initialize }
      tp.enable do
        GraphSweep.factories.each do |_name, factory|
          MB::Sound.seed(1)
          g = factory.call(GraphSweep::Context.new)
          GraphSweep.run(g, 64, 1)
        end
      end

      # An abstract base counts as built when a subclass is
      covered = ->(c) { built.any? { |b| b <= c } }
      missing = library_classes.reject { |c| covered.(c) || GraphSweep::EXEMPT.key?(c.name) }.map(&:name).sort
      expect(missing).to eq([])

      names = library_classes.map(&:name)
      expect(GraphSweep::EXEMPT.keys - names).to eq([]) # EXEMPT names classes that no longer exist
      stale = library_classes.select { |c| GraphSweep::EXEMPT.key?(c.name) && covered.(c) }.map(&:name)
      expect(stale).to eq([]) # EXEMPT lists classes the sweep builds
    end
  end
end

# The graph sweep's factories (see spec/lib/mb/sound/graph_sweep_spec.rb),
# shared with the graph-io round-trip specs (recipe_spec.rb).
require 'set'

module GraphSweep
  # buffer size => buffers; under Valgrind (SPEC_MEMCHECK) 20 one-sample
  # buffers instead of 40 (each is a full graph call, the costliest part
  # there; the 128- and 800-sample buffers, where the clips' events land,
  # are unchanged)
  SIZES = (SPEC_MEMCHECK ? { 1 => 20, 128 => 6, 800 => 3 } : { 1 => 40, 128 => 6, 800 => 3 }).freeze

  # Inputs shared by the factories (a new context per graph).
  class Context
    def s
      MB::Sound
    end

    # An audio-rate source (a band-limited saw)
    def sig(f = 110)
      f.hz.saw.at(0.5)
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

  # Biquads, lp4 modes, and the diode ladder inside feedback loops
  # (delay-fx-1's loop ops), constant and modulated.
  def self.loop_filter_factories
    biquads = MB::Sound::Filter::Cookbook::FILTER_TYPES.map { |t|
      gain = MB::Sound::Filter::SVF::GAIN_TYPES.include?(t)
      ["feedback biquad(#{t.inspect})", ->(c) {
        c.sig.feedback { |fb, input| input + fb.delay(40.samples).filter(t, cutoff: c.mod(400, 3000), quality: 1.2, gain: gain ? 1.5 : nil, structure: :biquad) * 0.4 }
      }]
    }
    ladders = MB::Sound::Filter::FourPole::MODES.keys.map { |m|
      ["feedback lp4(mode: #{m.inspect})", ->(c) {
        c.sig.feedback { |fb, input| input + fb.delay(40.samples).lp4(c.mod(300, 4000), resonance: c.mod(0, 0.7, 3), mode: m, drive: 1.5) * 0.5 }
      }]
    }
    ladders << ['feedback diode', ->(c) { c.sig.delay(0.002, feedback: 0.6) { |fb| fb.diode(c.mod(400, 3000), resonance: 0.4) } }]
    ladders << ['feedback lp4 and diode live drive (delays-2)', ->(c) {
      c.sig.feedback { |fb, input| input + (fb.delay(40.samples).lp4(1500, resonance: 0.5, drive: c.mod(0, 3)) + fb.delay(31.samples).diode(1200, resonance: 0.4, drive: c.mod(0.5, 2), drive_mode: :feedback)) * 0.4 }
    }]
    biquads + ladders
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
      ['lp4 and diode live drive nodes (delays-2)', ->(c) {
        c.sig.lp4(c.mod(200, 3000), resonance: 0.7, drive: c.mod(0, 4)) + c.sig.lp4(900, resonance: 0.8, drive: c.mod(0, 3), drive_mode: :stages) +
          c.sig.diode(1200, resonance: 0.6, drive: c.mod(0.5, 3)) + c.sig.diode(1200, resonance: 0.6, drive: c.mod(0, 3), normalize: false, drive_mode: :feedback, clip: :hard)
      }],
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
      ['LinearFollower', ->(c) { c.sig.filter(f::LinearFollower.new(sample_rate: 48000, max_rise: 100, max_fall: 50, absolute: true)) }],
      ['SimpleEnvelopeFollower', ->(c) { c.sig.filter(MB::Sound::GraphNode::Dynamics::SimpleEnvelopeFollower.new(sample_rate: 48000)) }],
      ['Smooth', ->(c) { c.sig.filter(f::Smooth.new(40.samples, sample_rate: 48000)) }],
      ['Smooth with a curve', ->(c) { c.sig.filter(f::Smooth.new(300.samples, sample_rate: 48000, curve: :elastic)) }],
      ['Smooth that lags (keep_up: false)', ->(c) { c.sig.filter(f::Smooth.new(200.samples, sample_rate: 48000, keep_up: false)) }],
      ['Biquad', ->(c) { c.sig.filter(f::Biquad.new(0.2, 0.4, 0.2, -0.3, 0.1, sample_rate: 48000)) }],
      ['Cookbook object', ->(c) { c.sig.filter(f::Cookbook.new(:peak, 48000, 1000, quality: 2, db_gain: 6)) }],
      ['Cookbook object as biquad', ->(c) { c.sig.filter(f::Cookbook.new(:lowpass, 48000, 1000, quality: 2), structure: :biquad) }],
      ['SVF object', ->(c) { c.sig.filter(f::SVF.new(:notch, 48000, 1000, quality: 2)) }],
      ['FilterChain', ->(c) { c.sig.filter(f::FilterChain.new(f::FirstOrder.new(:lowpass, 48000, 2000), f::Cookbook.new(:highpass, 48000, 100, quality: 0.7))) }],
      ['FilterSum', ->(c) { c.sig.filter(f::FilterSum.new(f::FirstOrder.new(:lowpass, 48000, 400), f::FirstOrder.new(:highpass, 48000, 4000))) }],
      ['Filter::Delay object', ->(c) { c.sig.filter(f::Delay.new(delay: 0.003, sample_rate: 48000, wet: 0.5, dry: 1)) }],
      ['NoiseColor pink', ->(c) { c.sig.filter(f::NoiseColor.new(:pink)) }],
      ['NoiseColor brown', ->(c) { c.sig.filter(f::NoiseColor.new(:brown)) }],
    ]
  end

  def self.node_factories
    [
      # Oscillators and Tone options
      ['sine', ->(c) { 440.hz.sine }],
      ['naive shapes', ->(c) { 220.hz.asquare + 330.hz.atriangle + 110.hz.asaw }],
      ['band-limited shapes', ->(c) { 220.hz.square + 330.hz.triangle.pwm(c.mod(0.1, 0.9)) + 110.hz.saw.fm(c.mod(-50, 50, 3)) }],
      ['complex shapes', ->(c) { (220.hz.complex_saw.pm(c.mod(-0.5, 0.5, 30)) + 220.hz.complex_square.pwm(0.3) + 330.hz.complex_triangle).real }],
      ['phasor', ->(c) { 100.hz.phasor }],
      ['sync and softsync', ->(c) { 200.hz.saw.sync(ratio: c.mod(1.2, 3)) + 150.hz.square.softsync(ratio: 2.3) }],
      ['sync to master tone', ->(c) { 300.hz.triangle.sync(97.hz.phasor) }],
      ['feedback sine', ->(c) { 220.hz.sine.fm_feedback(c.mod(0, 2.5), gain: c.mod(0.3, 1, 2)) }],
      ['tone gain node', ->(c) { 330.hz.saw.gain(c.mod(0, 1)) }],
      ['tone reset clean', ->(c) { 180.hz.saw.reset(c.trigger, clean: true) + 90.hz.square.reset(c.trigger, to: :random) }],
      ['noise', ->(c) { c.s.noise(seed: 3) + 220.hz.saw.noise(0.3, seed: 4) }],
      ['wavetable', ->(c) { 220.hz.wavetable(MB::Sound::Wavetable[:basic], scan: c.mod(0, 1, 2)) }],
      ['wavetable sync pwm', ->(c) { 220.hz.wavetable(MB::Sound::Wavetable[:saw]).sync(ratio: 1.7).pwm(0.3) }],
      ['wavetable sample mode reset', ->(c) {
        t = MB::Sound::Wavetable.from_samples(Numo::SFloat.new(4000).rand(-1, 1), mode: :sample, root: 440) rescue MB::Sound::Wavetable[:saw]
        220.hz.wavetable(t).reset(c.trigger)
      }],
      ['phase_table and waveshape', ->(c) { 50.hz.phasor.phase_table(MB::Sound::Wavetable[:saw], scan: 0.3) + c.sig.waveshape(MB::Sound::Wavetable[:sine]) }],
      ['harmonics (HarmonicTable)', ->(c) { 110.hz.harmonics([1, c.mod(0, 1), 0.3, 0.2], update: 64) }],
      ['unison', ->(c) { 220.hz.unison(5, detune: c.mod(0.05, 0.3, 1)) { |p, _i| p.saw } }],
      ['unison spread stereo', ->(c) { 220.hz.unison(4, spread: 1) { |p, _i| p.square } }],
      ['unison blockless', ->(c) { 220.hz.unison(3) * 1 }],
      ['unison blockless shape stereo', ->(c) { 220.hz.unison(4, spread: 1).square.pwm(0.3).filter(:lowpass, cutoff: 2000) }],
      ['tone unison', ->(c) { 220.hz.triangle.at(0.5).unison(3, detune: c.mod(0.05, 0.3, 1)) }],
      ['swarm', ->(c) { c.notes.hz.swarm(4, scatter: 1.oct) { |p, _i| p.saw } }],
      ['transpose node (SemitoneShift)', ->(c) { 220.hz.transpose(c.mod(-12, 12, 2)).saw }],
      ['vibrato', ->(c) { 220.hz.vibrato(5, depth: 0.5).saw }],
      # Tweens over keyframes, and note glides from a pitch (their Session
      # launch fixes, c38bd284 and 47ba5931, need a Session: tween_spec)
      ['tween and glide', ->(c) {
        c.sig.filter(:lowpass, cutoff: c.s.tween([300.0, 3000.0, 600.0], 1.n64, curve: :smooth), quality: 2) + c.notes.hz.glide(0.002, from: 110.hz).square.at(0.3)
      }],
      ['tempo tone (TempoNode)', ->(c) { 1.beat.hz.saw + 2.bars.lfo.square }],
      ['tempo delay', ->(c) { c.sig.delay(1.n32) }],

      # Arithmetic and routing
      ['arithmetic', ->(c) { (c.sig * c.mod(0, 1) + 0.1.constant - c.sig(55) / 2.constant.+(c.mod(0, 1))) }],
      ['note numbers to Hz (NoteFrequency)', ->(c) { c.mod(48, 60).freq.tone.ramp * 0.5 + c.s::C4.saw * 0.1 }],
      ['power, abs, rounding, logs', ->(c) { (c.mod(0.1, 2) ** 2.constant) + c.sig.aabs + c.sig.abs + (c.mod(0.5, 3).log + c.mod(1, 4).log2 + c.mod(1, 4).log10).floor + c.sig.round + c.sig.ceil }],
      ['complex parts', ->(c) { c.sig.real + 200.hz.complex_sine.imag + 200.hz.complex_sine.arg }],
      ['constant smooth', ->(c) { 0.5.constant(smoothing: 0.01) + c.sig }],
      ['smooth (B-spline, curve, adaptive, reset)', ->(c) {
        c.mod(0, 1).smooth(0.002) + c.sig.smooth(0.004, curve: :back, from: 0) + c.mod(-1, 1).smooth(1.ms..5.ms) +
          c.notes.number.smooth(0.003, reset: c.notes.trigger) * 0.01
      }],
      ['proc', ->(c) { c.sig.proc { |buf| buf * 0.5 } }],
      ['tee and branches', ->(c) { t = c.sig; t.softclip + t.delay(10.samples) + t }],
      ['with_buffer (BufferAdapter)', ->(c) { c.sig.with_buffer(37.samples) }],
      ['until and and_then (TimeLimit, NodeSequence, Silence)', ->(c) { c.sig.until(0.002).and_then(c.s.silence(0.001), c.sig(220)) }],
      ['ringdown', ->(c) { c.sig.until(0.003).ringdown }],
      ['sounding (Sounding)', ->(c) { c.s.noise * c.sig.until(0.003).sounding(hold: 0.001, fade: 0.0005) }],
      ['sample_hold', ->(c) { c.sig.sample_hold(c.trigger) + c.mod(0, 1).sah(range: -1..1) }],
      ['knob (held)', ->(c) { c.sig.filter(:lowpass, cutoff: MB::Sound::GraphNode::Knob.new(:held, 800, range: 50..4000, curve: :exp), quality: 2) }],
      ['knob moves (Knob, Knob::Reader: a ramp, a jump, a followed node)', ->(c) {
        k = MB::Sound::GraphNode::Knob.new(:sweep, 300, range: 50..4000, curve: :exp)
        k.ramp_to(2000, frames: 900, frame: 20, curve: :smooth)
        k.set(500, frame: 1500, smooth: 0)
        k.follow(c.mod(100, 3000), frame: 2400)
        c.sig.filter(:lowpass, cutoff: k, quality: 2) + k * 0.0001
      }],
      # (smoothing-1: delay(t, feedback:) is a feedback loop; a knob-read
      # gain was a loop input it couldn't read, and complex signals loop
      # their parts separately)
      ['delay feedback loops (knob gain, node gain and time, complex)', ->(c) {
        c.sig.delay(0.002, feedback: MB::Sound::GraphNode::Knob.new(:space, 0.5, range: 0.0..0.9) * 0.9, dry: 1) + c.sig.delay(c.mod(0.001, 0.0015), feedback: c.mod(-0.5, 0.5), wet: 0.5) +
          (c.sig + c.sig.delay(7.samples) * 1i).delay(30.samples, feedback: 0.4).real
      }],
      ['ArrayInput', ->(c) { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(3000).rand(-1, 1)], repeat: 2) }],
      ['NullInput', ->(c) { MB::Sound::NullInput.new(sample_rate: 48000, channels: 2) }],

      # Shapers
      ['shapers', ->(c) { c.sig.softclip + c.sig.clip(-0.3, 0.3) + c.sig.quantize(0.1) + c.sig.asoftclip + c.sig.aclip(-0.5, 0.2) + c.sig.aquantize(0.2) }],
      ['ease (CurveShaper)', ->(c) { c.sig.ease(:elastic) + c.sig.aease(:smoothstep) + c.sig.ease(:bounce, edges: :mirror) }],
      ['Quantize node', ->(c) { c.sig.quantize(c.mod(0.01, 0.2)) }],
      ['formant (Formant) constant and morphing', ->(c) {
        c.sig.formant(:a) + c.sig.formant(:a, :e, [[300, 0.db, 50], [900, -6.db, 60], [2500, -12.db, 100], [3300, -20.db, 120], [4000, -30.db, 150]], morph: c.mod(0, 1), shift: c.mod(-5, 5, 3), width: c.mod(0.5, 1.5, 2), voice: :soprano)
      }],
      ['decimate (Decimator)', ->(c) { c.sig.decimate(c.mod(500, 9000)) + c.sig.lp4(900, resonance: 0.6).decimate(3000.5, jitter: 0.3) + c.sig.srr(c.notes.freq * 3.5) + c.sig.decimate(2500, mix: 0.4) + c.sig.decimate(c.mod(800, 6000), mix: c.mod(0.1, 0.9)) + c.sig.decimate(c.mod(700, 7000), interpolation: :linear, jitter: 0.2) }],

      # Sampler (SamplerVoice: keys, velocity layers, loops, reverse, chops,
      # stereo samples; CaptureTap)
      ['sampler voices (SamplerVoice)', ->(c) {
        d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.07) * Math.exp(-i / 2000.0) })
        smp = MB::Sound::Sample[d]
        inst = MB::Sound::Sampler::Instrument.new { |i|
          i.region(smp.looped(500...1500, mode: :ping_pong), keys: 0..62, vel: 0..90)
          i.region(smp.rev.fade(in: 10, out: 30), keys: 0..62, vel: 91..127, seq: [1, 1])
          i.region(smp.looped(200...900, mode: :release), keys: 63..127, rand: 0.0...1.0, veltrack: 1)
        }
        st = MB::Sound::Sample[[d, d * -0.5]]
        brk = smp.slices(4)
        c.clip.synth(voices: 2) { |v, _i| inst.play(v) * 0.5 + st.play(v, transpose: 3)[0] * 0.25 } +
          brk.chop(0, [1, 3], brk[2].rev, MB::Sound::Rest).loop.sampler(brk) * 0.5 + smp[0...400].node
      }],
      # Choke groups (SF2 exclusive classes, SFZ group/off_by): the
      # allocator's :choke events stop SamplerVoices, fading those without
      # an envelope
      ['sampler choke groups (SamplerVoice choke)', ->(c) {
        d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.09) })
        smp = MB::Sound::Sample[d].looped(1000...2900)
        plain = MB::Sound::Sampler::Instrument.new { |i|
          i.region(smp, keys: 0..62, choke: 1)
          i.region(smp[0...2000], keys: 63..127, group: 1, off_by: 2, tune: 5)
        }
        enveloped = MB::Sound::Sampler::Instrument.new(envelope: [0.001, 0.01, 0.7, 0.05]) { |i| i.region(smp, choke: :all) }
        c.clip.synth(voices: 3) { |v, _i| plain.play(v) * 0.4 + enveloped.play(v) * 0.4 }
      }],
      # SoundFont-style instruments: per-zone envelope and filter values
      # (ZoneValue), panned regions, layers
      ['sampler zone values (ZoneValue), pans, layers', ->(c) {
        d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.05) })
        smp = MB::Sound::Sample[d].looped(1000...2900)
        zm = ->(a, b) { MB::Sound::Sampler::ZoneMap.new([[0..62, 0..127, a], [63..127, 0..127, b]]) }
        env = { segments: [[1, zm.(0.001, 0.01), 0], [zm.(0.5, 0.2), zm.(0.05, 0.1), 6], [0, 0.02, 100]], release_at: 2, sensitivity: nil }
        a = MB::Sound::Sampler::Instrument.new(envelope: env, filter: { cutoff: zm.(900, 5000), quality: zm.(0.7, 2) }) { |i|
          i.region(smp, keys: 0..62, pan: -0.5, veltrack: 1)
          i.region(smp, keys: 63..127, pan: 0.75, tune: 7)
        }
        # (b covers keys 40..70 only: a narrow layer, a Synth sub-lane)
        b = MB::Sound::Sampler::Instrument.new(envelope: { segments: [[1, 0.002], [0, 0.03]], release_at: 1, sensitivity: nil }) { |i| i.region(smp[0...1200], tune: 12, keys: 40..70) }
        inst = MB::Sound::Sampler::Instrument.layered(a, b)
        c.clip.synth(voices: 2) { |v, _i| inst.play(v) }.mixdown * 0.5
      }],
      ['grains (Grains)', ->(c) {
        d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.07) * Math.exp(-i / 2000.0) })
        smp = MB::Sound::Sample[d]
        st = MB::Sound::Sample[[d, d * -0.5]]
        smp.grains(density: c.mod(200, 900), size: c.mod(0.001, 0.004), spread: 0.2, pitch: [0, 12], pitch_spread: c.mod(0, 2), reverse: 0.3, seed: 1).mixdown * 0.3 +
          st.rev.grains(position: c.mod(0.1, 0.9), density: 500, size: 0.002, read: :drop, window: :expodec, jitter: 0, max_grains: 4, seed: 2)[1] * 0.3 +
          c.clip.synth(voices: 2) { |v, _i| v.grains(smp, density: 400, size: 0.002, seed: 3)[0] * 0.3 }
      }],
      ['loop players (LoopPlayer)', ->(c) {
        d = Numo::SFloat.cast(Array.new(3000) { |i| Math.sin(i * 0.07) * Math.exp(-(i % 750) / 200.0) })
        smp = MB::Sound::Sample[d, bpm: 960, beats: 1]
        st = MB::Sound::Sample[[d, d * -0.5], bpm: 960]
        smp.follow * 0.3 + smp.follow(:resample, align: :launch) * 0.3 + st.follow(stretch: { mode: :slice, slices: 4, fill: :stretch, cycle: 0.001 })[1] * 0.3
      }],
      ['capture tap (CaptureTap)', ->(c) { MB::Sound::GraphNode::CaptureTap.new(c.sig, MB::Sound::Sampler::AudioCapture.new(100_000)) + c.sig }],

      # Delays and reverbs
      ['delay modulated', ->(c) { c.sig.delay(c.mod(0.001, 0.004, 3), feedback: c.mod(0, 0.6), wet: 0.5, dry: 0.5) }],
      ['delay inserts compensated by time (:pitch comb, :echo echo; delays-2)', ->(c) {
        c.sig.delay(96.samples, feedback: 0.7) { |fb| fb.filter(:highpass, cutoff: 30, quality: 0.7) } +
          c.sig.delay(0.021, feedback: c.mod(0.2, 0.6)) { |fb| fb.filter(:highpass, cutoff: 200, quality: 0.5).filter(:lowpass, cutoff: 3000) }
      }],
      ['delay cubic and linear', ->(c) { c.sig.delay(c.mod(0.001, 0.003), interpolation: :cubic) + c.sig.delay(0.0021, interpolation: :linear) }],
      ['multitap', ->(c) { c.sig.multitap(0.001, c.mod(0.002, 0.003), 37.samples).mixdown }],
      ['multitap feedback (DelayNetwork)', ->(c) { c.sig.multitap(0.001, c.mod(0.002, 0.003), 37.samples, feedback: [0.3, c.mod(0, 0.4), 0], smooth: true).mixdown }],
      ['tape_echo presets (TapeEcho: wobbled delay times, loops with :dc compensation)', ->(c) {
        c.sig.tape_echo(:reel, time: 0.002, feedback: c.mod(0.3, 0.7)) + c.sig.tape_echo(:dub, time: 0.0017).at(0.5) +
          c.sig.tape_echo(:ping_pong, time: 0.0011, wow: 0, spread: 0.5).mixdown + c.stereo_sig.tape_echo(:slapback, time: 0.001).mixdown
      }],
      ['ping_pong and haas', ->(c) {
        c.sig.ping_pong(c.mod(0.001, 0.002), feedback: c.mod(0.2, 0.6), spread: 0.5, mix: 0.4).mixdown +
          c.stereo_sig.ping_pong(0.0013, feedback: -0.5, input: :stereo, interpolation: :cubic).mixdown +
          c.sig.haas(0.0007, side: :left, level: c.mod(0.5, 1)).mixdown
      }],
      ['reverb', ->(c) { c.stereo_sig.reverb(:room) }],
      ['reverb room-size factory', ->(c) { c.sig.reverb(room_size: 0.3, decay: 0.5, damping: 0.5) + c.sig.reverb(room_size: 0.2, decay: 0.3, output_channels: 2).mixdown }],
      ['reverb modulation and loop processing', ->(c) {
        c.stereo_sig.reverb(:room, mod: :lush, diffusion_mod: :subtle, lowpass: 4000, highpass: 80, drive: 2, crush: 10, shimmer: 0.3).mixdown
      }],
      ['reverb parameter nodes', ->(c) {
        c.sig.reverb(room_size: 0.2, decay: 0.4, mod: { depth: c.mod(0, 0.001), rate: c.mod(0.2, 2) }, lowpass: c.mod(500, 8000), freeze: c.mod(0, 1), stretch: c.mod(0.8, 1.2), shimmer: c.mod(0, 1), drive: c.mod(0, 3), drive_mode: :fold, duck: c.mod(0, 12), gate: c.mod(0, 0.1))
      }],
      ['reverb gain nodes (live mix, wet, dry, level, predelay; delays-2)', ->(c) {
        c.stereo_sig.reverb(:room, mix: c.mod(0, 1), level: c.mod(0.5, 1), predelay: c.mod(0.0005, 0.002)).mixdown + c.sig.reverb(:room, wet: c.mod(0, 1), dry: c.mod(0.2, 1))
      }],
      ['tape_echo live settings (tone, low_cut, drive, wow, flutter nodes; delays-2)', ->(c) {
        c.sig.tape_echo(:reel, time: 0.002, tone: c.mod(800, 6000), low_cut: c.mod(50, 400), drive: c.mod(0, 3), wow: c.mod(0, 0.5), flutter: c.mod(0, 0.1))
      }],
      ['chorus', ->(c) { c.stereo_sig.chorus(:juno2) }],
      ['chorus with hiss (HissGate)', ->(c) { c.sig.chorus(:juno1, hiss: -60.db) }],

      # Dynamics
      ['compress (rms, sidechain, lookahead, hold, upward, node times)', ->(c) {
        c.stereo_sig.compress(threshold: -20.db, ratio: 4, detector: :rms, lookahead: 8.samples, hold: 0.002, sidechain: c.sig(55),
                              upward_threshold: -40.db, attack: c.mod(0.001, 0.01), release: 1.n16, makeup: :auto)
      }],
      ['compand cubic, expand, noise_gate, duck', ->(c) {
        c.sig.compand({ -60.db => -70.db, -20.db => -20.db, 0.db => -10.db }, interpolation: :cubic).expand(threshold: -30.db).noise_gate(threshold: -60.db).duck(c.trigger, amount: -6.db)
      }],
      ['compress, expand, duck with live threshold, ratio, mix (delays-2)', ->(c) {
        c.stereo_sig.compress(threshold: c.mod(0.02, 0.3), ratio: c.mod(1, 8), mix: c.mod(0, 1), makeup: :auto).mixdown.expand(threshold: c.mod(0.001, 0.05), ratio: c.mod(1, 4)).duck(c.trigger, threshold: c.mod(0.01, 0.2))
      }],
      ['compand unlinked with shaped segments', ->(c) { c.stereo_sig.compand([[-60.db, -70.db, :smooth], [-20.db, -20.db], [0.db, -8.db]], link: false) }],
      ['limit (true peak, unlinked) after squeeze', ->(c) { c.stereo_sig.squeeze(:eleven, depth: 0.5).limit(ceiling: -3.db, link: false) }],
      ['squeeze default, mono', ->(c) { c.sig.squeeze(time: 0.5) }],
      ['bands LR2 inside LR8', ->(c) { c.sig.bands(300, order: 2) { |lo, hi| [lo, hi.bands(3000, order: 8) { |a, b| [a, b * 0.5] }] } }],
      ['ping (Resonator)', ->(c) { c.trigger.ping(c.mod(200, 2000), decay: 0.05) }],
      ['resonate (ModalResonator), mono and spread', ->(c) {
        c.trigger.resonate(:bowl, c.mod(200, 900), decay: c.mod(0.05, 0.2)) + c.trigger.resonate(:gong, 150, decay: 0.1, spread: c.mod(0, 1)).mono
      }],
      ['dust and drift (Dust, Drift)', ->(c) {
        MB::Sound.dust(c.mod(100, 3000), bipolar: true, seed: 3).ping(c.mod(500, 2000), decay: 0.01) +
          c.sig * MB::Sound.drift(c.mod(20, 400), smooth: :cosine, walk: 0.3, seed: 4) +
          MB::Sound.dust(1.n32, seed: 5) * MB::Sound.drift(3.ms, range: 0..1, seed: 6)
      }],

      # Feedback loops
      ['feedback one-pole', ->(c) { c.sig.feedback { |fb, input| input + (fb - input) * 0.9 } }],
      ['feedback Karplus-Strong', ->(c) {
        c.trigger.feedback { |fb, input| input + fb.delay(c.mod(0.002, 0.004, 1)).filter(:lowpass, cutoff: 3000) * 0.95 }
      }],
      ['feedback shapers and arithmetic', ->(c) {
        c.sig.feedback { |fb, input| input + (fb.delay(23.samples, interpolation: :cubic) * c.mod(0.2, 0.7)).softclip.quantize(0.01).clip(-1, 1).abs / 2.constant ** 1.constant }
      }],
      ['feedback stereo', ->(c) { c.stereo_sig.feedback { |fb, input| input + fb.delay(0.001) * 0.5 } }],
      # (omnibus16: a node delay time with the default smoothing starts at
      # its first value)
      ['delay with a node time and default smoothing', ->(c) { c.sig.delay(c.mod(0.001, 0.003)) + c.sig.delay(c.mod(40, 90).samples, smooth: 0.1) }],
      # (omnibus16: #delay's echo compensation, low cuts and bandpasses as
      # wires, with moving cutoffs and a d.fb pipeline)
      ['delay echo loop with a low cut (compensate: :echo)', ->(c) {
        c.sig.delay(0.002, feedback: c.mod(0.3, 0.7)) { |fb| fb.filter(:highpass, cutoff: c.mod(80, 400), quality: 0.5).filter(3000.hz.lowpass(quality: 0.5)).softclip(0, 0.5) } +
          c.sig.delay(0.0013, feedback: 0.5) { |d| d.fb { |fb| fb.filter(:bandpass, cutoff: c.mod(500, 2000), quality: 1) } }
      }],

      # Multichannel
      ['pan, balance, width', ->(c) { c.sig.pan(c.mod(-1, 1)).width(c.mod(0, 2)) + c.stereo_sig.balance(0.3) }],
      ['mid_side, swap, mono', ->(c) { c.stereo_sig.mid_side.from_mid_side.swap.mono }],
      ['matrix and place', ->(c) { c.stereo_sig.matrix([[1, 0.5], [0.2, c.mod(0, 1)], [0.3, 0.3]]) + c.sig.place(x: c.mod(-1, 1), y: 0.5).channels(0, 1).mixdown rescue c.stereo_sig.matrix([[1, 0.5], [0.2, 1]]) }],
      ['complex matrix (Analytic)', ->(c) { c.stereo_sig.matrix([[1, 1i], [0.5, -1i]]) }],
      ['stereo filter, lp4, softclip', ->(c) { c.stereo_sig.filter(:lowpass, cutoff: c.s.channels(500, 900), quality: 2).lp4(1000, resonance: 0.5).softclip }],
      ['left/right', ->(c) { c.stereo_sig.left + c.stereo_sig.right }],
      ['loudness_meter', ->(c) { c.stereo_sig.loudness_meter }],
      ['ride', ->(c) { c.stereo_sig.ride(-14, down: 0.05, up: 0.05) }],
      ['master :club', ->(c) { c.stereo_sig.master(:club) }],
      ['master :vinyl', ->(c) { c.stereo_sig.master(:vinyl) }],
      ['master :club, air: :dynamic and :band', ->(c) { c.stereo_sig.master(:club, air: :dynamic) + c.stereo_sig.master(:club, air: :band, clip: true) }],
      ['resample and oversample', ->(c) { c.sig.resample(44100) + c.sig.oversample(2) { |n| n.softclip } }],
      ['MixSource (master chain input)', ->(c) { MixFeeder.new(c.stereo_sig) { |mix| mix.softclip.filter(:highpass, cutoff: 50).mixdown } }],
      ['BusTap (bus and track readers; silence outside a Session, see buses_spec)', ->(c) { c.sig.duck(:sweep_drums, only: :kick) + MB::Sound.bus(:sweep_bus).mixdown + c.sig.compress(sidechain: MB::Sound.bus(:sweep_bus)) }],

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
        n.hz.saw.lp4(n.cutoff(800, env: n.filt_env), resonance: n.reso(0.5)) * n.amp_env + n.hz.glide(0.01).square.filter(:lowpass, cutoff: 900, quality: n.quality(2)) * n.fm_env(gm: true)
      }],
      ['notes lfo and fade-in', ->(c) { c.notes.lfo(5, delay: 0.002) + c.notes.lfo(3, shape: :noise) + c.notes.hz.vibrato(5).sine }],
      ['synth', ->(c) { c.clip.synth(voices: 2) { |v, _i| v.hz.saw.filter(:lowpass, cutoff: v.cutoff(1000)) * v.amp_env(0.001, 0.002, 0.5, 0.002) } }],
      ['synth stereo voices', ->(c) { c.clip.synth(voices: 2) { |v, _i| (v.hz.saw * v.env).pan(0.3) } }],
      # Controller lanes (midi-import-1): stepped and fitted CC lanes and a
      # bend with an RPN range, read by synth voices
      ['synth on a clip with controller lanes', ->(c) {
        clip = c.s.events(
          [0r, 1r/128, 60, 0.8], [1r/64, 1r/128, 64, 0.6, { slid: true }], [1r/32, 1r/64, 67, 0.9], length: 1r/16, loop: true,
          controls: { cc1: [[0r, 0.1], [1r/128, 0.5], [3r/128, 0.9]], cc74: { curve: :cubic, points: [[0r, 0.2], [1r/64, 0.8], [1r/32, 0.4]], resolution: 1r/1024 },
                      bend: { points: [[0r, 0.0], [1r/64, 0.3]], range: 12 } }
        )
        clip.synth(voices: 2) { |v, _i| v.hz.saw.filter(:lowpass, cutoff: v.cc(74).at(300..3000)) * v.mod * v.amp_env(0.001, 0.002, 0.5, 0.002) }
      }],
      ['drums (Kit, Voice)', ->(c) { c.s.tr808(c.s.grid(16, bd: 'x.x.', snare: '.x..', hat: 'xxxx')) }],
      # Kit builder (Drums::Machine, Hit layers, Repeats bursts, Flams,
      # ChokeGate) and the TR-909 (sampled hats through SamplerVoice)
      ['drums 909 (Repeats, ChokeGate)', ->(c) {
        c.s.tr909(c.s.grid(32, bd: 'x.x.', clap: '.x..', hat: 'x.x.', oh: 'xx..', ride: '..x.', snare: '..f.'), flam: 0.001, shuffle: 2)
      }],
      ['drums kit builder', ->(c) {
        c.s.kit(c.s.grid(32, kick: 'x.x.', snare: '.x.x', hat: 'xx..', oh: '..xx')) {
          voice(:kick) { |h| h.body(50, sweep: 2, drop: 0.3).softclip(0.6) + h.click }
          voice(:snare) { |h| h.fm(200, index_decay: 0.01) + h.noise(bandpass: 2000) + h.bursts(3, 0.0003) }
          voice(:closed_hat) { metal * env(0.01) * velocity }
          tr808 :open_hat
          choke :open_hat, :closed_hat
        }
      }],
      # (omnibus17, Kez's K5 and Odile's F12: stereo Samples as voices play
      # mixed down; they raised in Drums::Voice#initialize)
      ['drums kit builder, stereo sample voices', ->(c) {
        l = Numo::SFloat.cast(Array.new(300) { |i| Math.sin(i * 0.3) * 0.99**i })
        wood = MB::Sound::Sample[[l, l * -0.5]]
        c.s.kit(c.s.grid(32, kick: 'x.x.', clap: '.x.x')) {
          voice :kick, wood
          voice(:clap) { |h| h.sample(wood, tune: 3) + h.click }
        }
      }],

      # Plan lane groups (Plan::LaneGroup: FastPlan.run_lanes with the
      # lane-major SVF, four-pole, diode, and biquad kernels, wavetable
      # tones, sample and hold, tempo params)
      ['synth lane groups (lane-major filters)', ->(c) {
        c.clip.synth(voices: 3, spares: 1) { |v, _i|
          saw = v.hz.saw * v.amp_env(0.001, 0.002, 0.5, 0.002)
          saw.filter(:lowpass, cutoff: v.cutoff(1000), quality: 2) + saw.lp4(v.cutoff(1500), resonance: 0.4) * 0.5 +
            saw.diode(v.cutoff(700), resonance: 0.6, drive: 1.5) * 0.3 + saw.filter(:highpass, cutoff: v.cutoff(300), quality: 1, structure: :biquad) * 0.2
        }
      }],
      ['synth wavetable voices (KeyMap, sample and hold, tempo times)', ->(c) {
        km = MB::Sound::Wavetable::KeyMap.new(MB::Sound::C1...MB::Sound::C4 => :saw, MB::Sound::C4..MB::Sound::C8 => :square)
        c.clip.synth(voices: 2) { |v, _i|
          chop = v.env([[1, 1.n64, 24], [0, 1.n64, -12], [0, 0.002]], release_at: 2, loop: 0, curve: :linear, sensitivity: 0, gm: false)
          v.hz.wavetable(km, scan: v.lfo(3, shape: :noise) * 0.5 + 0.5).pwm(0.4) * v.amp_env(0.001, 0.002, 0.5, 0.002) * chop
        }
      }],
      ['stereo channels of one shape (installation lane group)', ->(c) {
        c.s.stereo(c.sig(110).filter(:lowpass, cutoff: c.mod(400, 900)) * 0.5, c.sig(165).filter(:lowpass, cutoff: c.mod(500, 800, 5)) * 0.5)
      }],
    ]
  end

  def self.factories
    node_factories + svf_factories + biquad_factories + four_pole_factories + loop_filter_factories + filter_object_factories
  end

  # Node classes the sweep doesn't build, with reasons.
  EXEMPT = {
    'MB::Sound::Envelope::PreviewGate' => "the envelope preview copy's one-note gate (a display render); envelope_view_spec runs it",
    'MB::Sound::DeviceInput' => 'sound card input; device_input_spec runs it',
    'MB::Sound::Mastering::Targeting::Tap' => "records a render's first pass at a preset's trim; mastering_spec's targeted renders run it",
    'MB::Sound::Mastering::Targeting::Tap::Output' => 'an output of Mastering::Targeting::Tap (see there)',
    'MB::Sound::Mastering::Targeting::TrimCurve::Node' => "a measure: :sections render's per-section trim (reads Session#frame); mastering_measure_spec's sections render runs it",
    'MB::Sound::FFMPEGInput' => 'file input through ffmpeg (not traced by Valgrind)',
    'MB::Sound::IOInput' => 'base of FFMPEGInput',
    'MB::Sound::InputBufferWrapper' => 'wraps an input stream for window readers, not a graph node in use',
    'MB::Sound::OutputBufferWrapper' => 'wraps an output stream for window writers',
    'MB::Sound::GraphNode::DataShuffler' => 'test/debug helper with no DSL entry point',
    'MB::Sound::Filter::FilterBank' => 'parallel filters over Arrays of plain data, not used in graphs',
  }.freeze

  # Buffer size and count of the Notes reference path pass (Kernels
  # notes_fast: :ruby, the Ruby mirror of the Notes fast paths) for graphs
  # with Notes nodes: one-sample buffers, where the reference path
  # rewrites its reused buffers every block and the fast paths hand out
  # frozen constants (cleanup-2: a drum Voice's Tap passed a Notes
  # trigger's reused buffer to a Tee, which the trigger rewrote before the
  # Tee's next frame).  As many buffers as the main pass's one-sample
  # size (fewer under memcheck).
  NOTES_REFERENCE = [1, SIZES[1]].freeze

  # True if +graph+ (a node or bundle) has a Notes node.
  def self.notes?(graph)
    outs = graph.respond_to?(:outputs) ? graph.outputs.to_a : [graph]
    outs.any? { |o| o.respond_to?(:graph) && o.graph.any? { |n| n.is_a?(MB::Sound::Notes::Node) } }
  end

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

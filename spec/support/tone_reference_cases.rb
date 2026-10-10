# Oscillator cases for the Tone null-test reference (tone_reference_spec.rb,
# spec/test_data/make_tone_reference.rb): every shape, band-limited and
# naive, warps, sync, FM/PM, resets, random phases, LFO band-limit fades,
# ports, sample rates, oversampling, channels, tempo LFOs with seeks,
# pauses, and freewheeling, and Notes key sync.  Recorded from the code
# before the Tone/Oscillator consolidation (2026-10-06), so the refactor can
# show it changed nothing.
#
# Each case returns a Hash of named outputs (NArrays).  When the API
# changes, a case is rewritten in the new API to describe the same sound.
# Noise cases were added with the per-tone noise generator (2026-10-06;
# before, FastSound drew from the process-wide drand48, so noise samples
# depended on what ran before).
module ToneReferenceCases
  S = MB::Sound

  # Irregular buffer sizes, so buffer edges land everywhere.
  SIZES = [128, 37, 300, 1, 512, 222].freeze

  module_function

  # Reads +total+ samples of +node+ (and of its +ports+, by name, read in
  # the same buffers) in SIZES pieces.  Returns { 'main' => ..., port => ... }.
  def render(node, total: 1200, ports: [], sizes: SIZES)
    port_nodes = ports.to_h { |p| [p.to_s, node.public_send(p)] }
    out = { 'main' => [] }.merge(port_nodes.transform_values { [] })
    done = 0
    i = 0
    while done < total
      n = [sizes[i % sizes.length], total - done].min
      out['main'] << node.sample(n).dup
      port_nodes.each { |name, p| out[name] << p.sample(n).dup }
      done += n
      i += 1
    end

    out.transform_values { |bufs| bufs[0].concatenate(*bufs[1..]) }
  end

  # Renders +buffers+ buffers of +buffer_size+ from a non-realtime Session
  # at +bpm+, calling the block with (session, transport, index) before
  # each buffer (index 0 is before the first, for adding players).
  # Returns { 'left' => ..., 'right' => ... }.
  def session(bpm:, buffers:, buffer_size: 480)
    transport = S::Sequence::Transport.new(bpm: bpm)
    output = S::NullOutput.new(channels: 2, sleep: false)
    session = S::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: buffer_size, realtime: false, raise_errors: true)
    left = []
    right = []
    buffers.times do |i|
      yield session, transport, i
      l, r = session.process_buffer
      left << l.dup
      right << r.dup
    end
    { 'left' => left[0].concatenate(*left[1..]), 'right' => right[0].concatenate(*right[1..]) }
  ensure
    session&.close
  end

  # An ArrayInput of zeros with +value+ at +indices+ (repeating every
  # +length+ samples if +repeat+).
  def triggers(length, *indices, value: 1.0, repeat: true)
    data = Numo::SFloat.zeros(length)
    indices.each { |i| data[i] = value }
    S::ArrayInput.new(data: [data], repeat: repeat)
  end

  # A node that steps through +values+ every +length+ samples, repeating.
  def steps(length, *values)
    S::ArrayInput.new(data: [Numo::SFloat.cast(values.flat_map { |v| [v] * length })], repeat: true)
  end

  CASES = {}

  # Shapes, band-limited and naive, low and high
  [:sine, :triangle, :square, :ramp, :gauss, :parabola, :atriangle, :asquare, :aramp].each do |wave|
    [110, 3520].each do |f|
      CASES["#{wave}_#{f}"] = -> { render(f.hz.public_send(wave).at(0.5)) }
    end
  end

  [:complex_sine, :complex_square, :complex_triangle, :complex_ramp,
   :acomplex_square, :acomplex_triangle, :acomplex_ramp].each do |wave|
    CASES["#{wave}_330"] = -> {
      out = render(330.hz.public_send(wave).at(0.5))['main']
      { 'real' => out.real, 'imag' => out.imag }
    }
  end
  CASES['complex_ramp_pm'] = -> {
    out = render(330.hz.complex_ramp.pm(55.hz.at(0.3).radians).at(0.5))['main']
    { 'real' => out.real, 'imag' => out.imag }
  }

  CASES.merge!(
    'drumramp' => -> { render(220.hz.drumramp.at(0.5)) },
    'phase_60deg' => -> { render(220.hz.sine.with_phase(1.0 / 6).at(0.5)) },
    'range' => -> { render(30.hz.triangle.at(-0.2..0.7)) },
    'negative_amp' => -> { render(440.hz.square.at(-0.3)) },
    'slow_ramp' => -> { render(0.3.hz.ramp.at(0.5)) },
    'negative_freq' => -> { render(-440.hz.ramp.at(0.5)) },
    'tone_new' => -> { render(S::Tone.new(wave_type: :triangle, frequency: 330, amplitude: 0.5)) },
    'tone_bracket' => -> { render(S::Tone[220].ramp) },
    'oscillator_direct' => -> { render(S::Tone.new(wave_type: :triangle, frequency: 330).atriangle.at(-0.5..0.5)) }, # was Oscillator.new(:triangle, frequency: 330, range: -0.5..0.5)

    # Warps
    'pulse' => -> { render(1760.hz.pulse(0.25).at(0.5)) },
    'apulse' => -> { render(1760.hz.apulse(0.25).at(0.5)) },
    'pulse_dc' => -> { render(220.hz.pulse(0.1, dc: true).at(0.5)) },
    'pwm_node' => -> { render(220.hz.pwm(30.hz.lfo.at(0.05..0.95)).square.at(0.5)) },
    'skew_triangle' => -> { render(440.hz.triangle.skew(0.1).at(0.5)) },
    'sine_pwm' => -> { render(220.hz.sine.pwm(0.2).at(0.5)) },
    'ramp_pwm' => -> { render(330.hz.ramp.pwm(0.7).at(0.5)) },
    'parabola_pwm' => -> { render(330.hz.parabola.pwm(0.3).at(0.5)) },

    # Sync
    'sync_ratio' => -> { render(110.hz.ramp.sync(ratio: 2.37).at(0.5)) },
    'sync_ratio_node' => -> { render(110.hz.ramp.sync(ratio: 20.hz.lfo.at(1..5)).at(0.5)) },
    'async_ratio' => -> { render(110.hz.aramp.sync(ratio: 2.37).at(0.5)) },
    'softsync' => -> { render(110.hz.triangle.softsync(ratio: 1.7).at(0.5)) },
    'sync_pitch_master' => -> { render(330.hz.square.sync(110.hz).at(0.5)) },
    'sync_tone_master' => -> {
      master = 110.hz.square.at(0.2)
      synced = 220.hz.pulse(0.3).sync(master).at(0.5)
      render(synced + master)
    },
    'sync_trigger' => -> { render(220.hz.ramp.sync(triggers(250, 0, value: 0.6)).at(0.5)) },
    'sync_pwm' => -> { render(220.hz.square.pwm(0.3).sync(ratio: 1.6).at(0.5)) },

    # Modulation
    'fm' => -> { render(220.hz.sine.fm(110.hz.sine.at(300)).at(0.5)) },
    'fm_index' => -> { render(220.hz.ramp.fm(110.hz, 300).at(0.5)) },
    'fm_through_zero' => -> { render(200.hz.ramp.fm(50.hz.at(600)).at(0.5)) },
    'fm_stack' => -> { render(200.hz.triangle.fm(600.hz.at(500)).fm(300.hz.at(200)).at(0.5)) },
    'log_fm' => -> { render(220.hz.sine.log_fm(55.hz.sine.at(2)).at(0.5)) },
    'pm' => -> { render(220.hz.sine.pm(330.hz.sine.at(2).radians).at(0.5)) },
    'pm_index' => -> { render(220.hz.square.pm(330.hz, 1.5.radians).at(0.5)) },
    'pm_chain' => -> { render(110.hz.triangle.pm(220.hz.sine.pm(440.hz.sine.at(1).radians).at(2).radians).at(0.5)) },
    'freq_node' => -> { render(steps(100, 200, 300, 450).tone.ramp.at(0.5)) },

    # LFOs (band-limiting fades in from 15 to 30 Hz)
    'lfo_ramp_5' => -> { render(5.hz.ramp.lfo, total: 2000) },
    'lfo_square_20' => -> { render(20.hz.square.lfo.at(0..1), total: 2000) },
    'lfo_ramp_100' => -> { render(100.hz.ramp.lfo) },
    'lfo_sweep' => -> { render(5.hz.lfo.at(5..60).tone.ramp.lfo, total: 2000) },

    # Resets
    'reset' => -> { render(1001.3.hz.ramp.reset(triggers(173, 37, 80, value: 0.25)).at(0.5)) },
    'reset_edges' => -> { render(997.hz.square.reset(triggers(128, 0, 127)).at(0.5), sizes: [128, 64, 64, 1, 127]) },
    'reset_to' => -> { render(440.hz.triangle.reset(triggers(300, 50), to: 0.25).at(0.5)) },
    'reset_to_node' => -> { render(440.hz.ramp.reset(triggers(300, 50, 210), to: steps(150, 0.5, 2.0).radians).at(0.5)) },
    'reset_random' => -> { render(330.hz.saw.reset(triggers(200, 20, 120), to: :random).at(0.5)) },
    'reset_fm_pm' => -> { render(500.hz.ramp.fm(70.hz.at(80)).pm(30.hz.at(0.5).radians).reset(triggers(256, 11, 130)).at(0.5)) },
    'reset_pwm' => -> { render(300.hz.pwm(10.hz.lfo.at(0.2..0.8)).square.reset(triggers(400, 99, 333)).at(0.5)) },
    'reset_naive' => -> { render(700.hz.aramp.reset(triggers(250, 60)).at(0.5)) },
    'reset_sine' => -> { render(1300.hz.sine.reset(triggers(222, 17)).at(0.5)) },
    'reset_complex' => -> {
      out = render(330.hz.complex_ramp.reset(triggers(300, 77)).at(0.5))['main']
      { 'real' => out.real, 'imag' => out.imag }
    },
    'reset_lfo' => -> { render(25.hz.lfo.square.reset(triggers(400, 150), to: 0.125)) },
    'rnd' => -> { render(220.hz.saw.rnd(seed: 3).at(0.5)) },
    'rnd_drawn' => -> { S.seed(5); render(220.hz.square.rnd.at(0.5)) },
    'rnd_reset' => -> { render(220.hz.saw.reset(triggers(300, 90)).rnd(seed: 9).at(0.5)) },
    'free' => -> { render(220.hz.saw.free.at(0.5)) },

    # Ports
    'tone_ports' => -> { render(1500.hz.ramp.fm(200.hz.at(300)).at(0.5), ports: [:wraps, :increment]) },
    'tone_ports_reset' => -> { render(1500.hz.ramp.reset(triggers(256, 40, 200)).at(0.5), ports: [:wraps, :increment]) },
    'tone_ports_negative' => -> { render(-1700.hz.ramp.at(0.5), ports: [:wraps]) },
    'phasor' => -> { render(1234.5.hz.phasor) },
    'phasor_phase' => -> { render(100.hz.phasor(phase: 0.25)) },
    'phasor_ports' => -> { render(S::Pitch.new(steps(64, 900, 3000)).phasor, ports: [:wraps, :increment]) },
    # 2000 Hz: 24 samples per cycle, every wrap exactly on a sample
    'phasor_wraps_only' => -> { { 'main' => render(2001.hz.phasor.wraps)['main'], 'at_2000' => render(2000.hz.phasor.wraps)['main'] } },

    # Noise (per-tone generators seeded from the root seed or seed:)
    'noise_root_seed' => -> { render(S.noise + 1.hz.gauss.noise.at(0.5)) },
    'noise_seeded_blend' => -> { render(300.hz.ramp.fm(90.hz.at(200)).noise(0.5, seed: 4).at(0.5)) },
    'noise_phasor' => -> { render(400.hz.phasor.noise(0.01, seed: 5)) },

    # Sample rates, oversampling, channels
    'rate_44100' => -> { render(1000.hz.ramp.at(0.5).at_rate(44100)) },
    'rate_96000_fm' => -> { render(1000.hz.square.fm(300.hz.at(200)).at(0.5).at_rate(96000)) },
    'rate_noise_blend' => -> { render(440.hz.sine.noise(false).at(0.5).at_rate(96000)) },
    'oversample' => -> { render(2000.hz.ramp.fm(3000.hz.at(4000)).at(0.5).oversample(4)) },
    'channels' => -> {
      l, r = S.channels(110.constant, 165.constant).tone
      { 'left' => render(l)['main'], 'right' => render(r)['main'] }
    },
    'notes' => -> { render(S::A4.triangle.at(0.5) + S::Cs5.square.at(0.3)) },
    'tuning_480' => -> {
      S.tuning b4: 480
      render(S::B4.ramp.at(0.5))
    },

    # Tempo LFOs (1920 BPM: a bar is 6000 frames, an n128 is 47 Hz)
    'tempo_lfo' => -> {
      session(bpm: 1920, buffers: 40) { |s, _t, i| s.add(1.bar.lfo.ramp) if i == 0 }
    },
    'tempo_lfo_changes' => -> {
      session(bpm: 1920, buffers: 60) { |s, t, i|
        s.add(1.beat.lfo.square.at(0.2..1) * 220.hz.ramp.at(0.5)) if i == 0
        t.bpm = 1500 if i == 13
        t.seek(3/8r) if i == 29
        t.seek(1/3r) if i == 44
      }
    },
    'tempo_audio_rate_seek' => -> {
      session(bpm: 1920, buffers: 30) { |s, t, i|
        s.add(1.n128.hz.ramp.at(0.5) + 1.n64.hz.square.with_phase(1.0.radians).at(0.3)) if i == 0
        t.seek(1/7r) if i == 9
        t.seek(5/9r) if i == 21
      }
    },
    'tempo_late_start' => -> {
      session(bpm: 1920, buffers: 30) { |s, _t, i|
        s.add(0.constant) if i == 0
        s.add(1.bar.lfo.ramp.with_phase(0.25), at: :beat) if i == 3
      }
    },
    'tempo_pause_freewheel' => -> {
      session(bpm: 1920, buffers: 40) { |s, _t, i|
        if i == 0
          s.add(0.constant.until(480 * 3 / 48000.0))
          s.master { |mix| mix + 1.bar.lfo.ramp.at(0.5) + (2.beats.lfo.triangle.freewheel * 0.25) }
        end
        s.add(0.constant) if i == 20
      }
    },
    'tempo_pitch_freewheel' => -> {
      session(bpm: 1920, buffers: 30) { |s, t, i|
        if i == 0
          p = 1.beat.hz
          p.freewheel
          s.add(p.ramp.lfo.at(0.5) + p.phasor * 0.25)
        end
        t.seek(1/5r) if i == 11
      }
    },
    'tempo_phasor' => -> {
      session(bpm: 1920, buffers: 30) { |s, t, i|
        s.add(1.beat.hz.phasor(phase: 0.25)) if i == 0
        t.seek(2/3r) if i == 17
      }
    },
    'tempo_lfo_reset' => -> {
      session(bpm: 1920, buffers: 30) { |s, t, i|
        s.add(1.bar.lfo.ramp.reset(triggers(1000, 300))) if i == 0
        t.seek(1/4r) if i == 15
      }
    },

    # Clip and synth key sync
    'clip_tone' => -> {
      session(bpm: 960, buffers: 60) { |s, _t, i|
        if i == 0
          bass = S.seq(S::C2, S::G1, S.rest, S::C3).n8.loop
          s.add(bass.tone.ramp.at(0.5) * bass.env)
        end
      }
    },
    'clip_synth' => -> {
      session(bpm: 960, buffers: 60) { |s, _t, i|
        if i == 0
          clip = S.seq(S::C3, S::E3.n16, S::G3, S::C4.n16).n8.legato(1.5).loop
          # skip_idle: false: the reference pins oscillators, not idle-lane skipping
          # (clip synths skip idle lanes since 2026-10-10)
          s.add(clip.synth(voices: 2, skip_idle: false) { |v| (v.hz.saw.at(0.3) + v.hz.vibrato(6, depth: 30.cents).transpose(7).square.at(0.2)) * v.amp_env(0.002, 0.05, 0.6, 0.02) })
        end
      }
    },
    'clip_key_sync_variants' => -> {
      session(bpm: 960, buffers: 50) { |s, _t, i|
        if i == 0
          clip = S.seq(S::A2, S::E3, S::D3).n8.loop
          n = clip.notes
          s.add(n.hz.ramp.at(0.3) + n.hz.transpose(12).square.free.at(0.2) + n.hz.triangle.rnd(seed: 4).at(0.2) + n.hz.sine.lfo.at(0.1))
        end
      }
    },
  )
end

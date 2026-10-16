require_relative '../../../support/sf2_writer'

RSpec.describe(MB::Sound::Sampler::SF2, :aggregate_failures) do
  let(:sf2) { described_class }
  let(:m) { MB::Sound }

  # Plays +clip+ (at 120 BPM: a whole note is 2 s) on +inst+ for +n+
  # samples in buffers of +size+; returns one SFloat per channel.
  def play(inst, clip, n, size: 800, voices: 4)
    syn = m.synth(clip.stream(transport: m::Sequence::Transport.new(bpm: 120)), voices: voices) { |v| inst.play(v) }
    outs = syn.respond_to?(:outputs) ? syn.outputs.to_a : [syn]
    bufs = outs.map { [] }
    got = 0
    while got < n
      c = [size, n - got].min
      outs.each_with_index { |o, i| bufs[i] << o.sample(c).dup }
      got += c
    end
    bufs.map { |b| Numo::SFloat.hstack(b) }
  end

  # The frequency of a sine-like +x+ from rising zero crossings (between
  # the first and last, so it's exact to a fraction of a Hz over a second).
  def freq(x, rate = 48000)
    z = ((x[0...-1] < 0) & (x[1..] >= 0)).where
    (z.length - 1) * rate.to_f / (z[-1] - z[0])
  end

  def font(**options)
    path = tmp_path(options.delete(:file) || 'spec.sf2')
    SF2Writer.write(path, **options)
  end

  # A font of one preset playing one sine sample over every key.
  def sine_font(gens = {}, sample: {}, preset: {}, global: nil, **options)
    font(
      samples: [{ name: 'sine', data: SF2Writer.sine(441, 4410), rate: 44100, pitch: 69, loop: [0, 4400] }.merge(sample)],
      instruments: [{ name: 'Sine', global: global, zones: [{ sample_id: 0 }.merge(gens)] }],
      presets: [{ name: 'Sine', program: 0, zones: [{ instrument: 0 }.merge(preset)] }],
      **options
    )
  end

  describe 'presets' do
    let(:path) {
      inst = [{ name: 'I', zones: [{ sample_id: 0 }] }]
      font(
        samples: [{ name: 's', data: SF2Writer.sine(441, 100) }], instruments: inst,
        presets: [
          { name: 'Warm Pad', program: 89, zones: [{ instrument: 0 }] },
          { name: 'Grand Piano', program: 0, zones: [{ instrument: 0 }] },
          { name: 'Standard', bank: 128, program: 0, zones: [{ instrument: 0 }] },
          { name: 'Metal Pad', program: 93, zones: [{ instrument: 0 }] },
        ]
      )
    }

    it 'lists presets by bank and program and chooses them by program, [bank, program], or name' do
      f = m.sf2(path)
      expect(f).to be_a(sf2::Font)
      expect(m.sf2(path)).to equal(f) # cached while in use
      expect(f.name).to eq('Spec Font')
      expect(f.presets.map { |p| [p.bank, p.program, p.name] }).to eq([[0, 0, 'Grand Piano'], [0, 89, 'Warm Pad'], [0, 93, 'Metal Pad'], [128, 0, 'Standard']])
      expect(f.presets.to_s).to eq("spec.sf2: 4 presets\n000:000 Grand Piano\n000:089 Warm Pad\n000:093 Metal Pad\n128:000 Standard")
      expect(f.preset.name).to eq('Grand Piano')
      expect(f.preset(89).name).to eq('Warm Pad')
      expect(f.preset([128, 0]).name).to eq('Standard')
      expect(f.preset('warm pad').name).to eq('Warm Pad')
      expect(f.preset(:metal).name).to eq('Metal Pad')
      expect(f[128, 0].name).to eq('Standard')
      expect(m.sf2(path, 89).name).to eq('Warm Pad')
      expect(m.sf2(path, preset: 'Grand').name).to eq('Grand Piano')
      expect { f.preset('Pad') }.to raise_error(ArgumentError, /matches 2 presets: 000:089 Warm Pad, 000:093 Metal Pad/)
      expect { f.preset('Grand Pino') }.to raise_error(ArgumentError, /did you mean "Grand Piano"/)
      expect { f.preset(5) }.to raise_error(ArgumentError, /no preset 5/)
      expect(f.play(m.seq(m::C4.n4).notes).sample(800).abs.max).to be > 0.01 # the first preset
    end

    it 'refuses files that are not SoundFonts' do
      bad = tmp_path('x.sf2')
      File.binwrite(bad, 'RIFF....WAVEfmt ')
      expect { m.sf2(bad) }.to raise_error(ArgumentError, /isn't a SoundFont 2 file/)
    end
  end

  describe 'zones' do
    it 'puts instrument global zones under local zones and adds preset generators' do
      path = font(
        samples: [{ name: 'a', data: SF2Writer.sine(441, 1000), pitch: 69, correction: -7 }, { name: 'b', data: SF2Writer.sine(441, 1000), pitch: 255 }],
        instruments: [{
          name: 'I', global: { initial_attenuation: 60, coarse_tune: 1, key_range: [10, 100] },
          zones: [
            { key_range: [0, 59], sample_id: 0 },
            { key_range: [60, 127], vel_range: [0, 63], coarse_tune: -2, fine_tune: 30, scale_tuning: 50, overriding_root_key: 72, sample_id: 1 },
            { initial_attenuation: 10 }, # not global (not first) and no sample: ignored
          ],
        }],
        presets: [{
          name: 'P', global: { initial_attenuation: 20, key_range: [20, 90] },
          zones: [{ coarse_tune: 12, fine_tune: -10, sample_modes: 1, overriding_root_key: 30, instrument: 0 }],
        }]
      )
      f = m.sf2(path)
      zones = f.zones
      expect(zones.length).to eq(2)
      a, b = zones
      expect(a.keys).to eq([20, 59]) # instrument local zone range intersected with the preset's
      expect(b.keys).to eq([60, 90])
      expect(b.vel).to eq([0, 63])
      expect(a.generators[:initial_attenuation]).to eq(80) # global 60 + preset 20
      expect(a.generators[:coarse_tune]).to eq(13)
      expect(b.generators[:coarse_tune]).to eq(10)
      expect(b.generators[:fine_tune]).to eq(20)
      expect(a.generators[:sample_modes]).to eq(0) # instrument-only generators are ignored in presets
      expect(b.generators[:overriding_root_key]).to eq(72)

      inst = f.instrument(attenuation: 1.0)
      ra, rb = inst.regions
      expect(ra.root).to eq(69)
      expect(ra.tune).to be_within(1e-12).of(13 + (-10 - 7) / 100.0)
      expect(ra.gain).to be_within(1e-12).of(10**(-80 / 200.0))
      expect(ra.veltrack).to eq(1)
      expect(ra.keytrack).to eq(1)
      expect(rb.root).to eq(72)
      expect(rb.keytrack).to eq(0.5)
      expect(rb.tune).to be_within(1e-12).of(10.2)
      expect(rb.sample.loop_mode).to eq(:no_loop)
      expect(rb.sample.sample_rate).to eq(44100)
      expect(f.instrument.regions[0].gain).to be_within(1e-12).of(10**(-32 / 200.0)) # EMU's 0.4 by default
      expect(m.sf2(path, preset: 0, name: 'x').name).to eq('x')

      # an original pitch of 255 (unpitched) plays at C4 unless overridden
      path2 = font(
        file: 'b.sf2', samples: [{ name: 'b', data: SF2Writer.sine(441, 1000), pitch: 255 }],
        instruments: [{ name: 'I', zones: [{ sample_id: 0 }] }], presets: [{ name: 'P', zones: [{ instrument: 0 }] }]
      )
      expect(m.sf2(path2, 0).regions[0].root).to eq(60)
    end

    it 'reads sample offsets, loop points, and loop modes' do
      path = sine_font(
        { start_addrs_offset: 10, end_addrs_offset: -100, startloop_addrs_offset: 5, endloop_addrs_offset: -5, sample_modes: 3 },
        sample: { loop: [1000, 3000] }
      )
      s = m.sf2(path, 0).regions[0].sample
      expect([s.start, s.stop]).to eq([10, 4310])
      expect(s.loop_points).to eq([1005.0, 2995.0])
      expect(s.loop_mode).to eq(:release)
      expect(m.sf2(sine_font({ sample_modes: 1 }, file: 'b.sf2'), 0).regions[0].sample.loop_mode).to eq(:forward)
      expect(m.sf2(sine_font({ sample_modes: 0 }, file: 'c.sf2'), 0).regions[0].sample.loop_mode).to eq(:no_loop)
      expect(m.sf2(sine_font({ sample_modes: 1, start_addrs_coarse_offset: 1 }, sample: { data: SF2Writer.sine(441, 40000), loop: [33000, 34000] }, file: 'd.sf2'), 0).regions[0].sample.start).to eq(32768)
    end

    it 'reads 16- and 24-bit samples' do
      data = Array.new(500) { |i| Math.sin(i * 0.1) * 0.9 }
      [false, true].each do |deep|
        f = m.sf2(font(file: "s#{deep}.sf2", samples: [{ name: 's', data: data }], instruments: [{ name: 'I', zones: [{ sample_id: 0 }] }],
                       presets: [{ name: 'P', zones: [{ instrument: 0 }] }], sm24: deep))
        got = f.sample_data(0)
        expect(got.length).to eq(500)
        err = (Numo::DFloat.cast(got) - Numo::DFloat.cast(data)).abs.max
        expect(err).to be < (deep ? 2.0 / 8388608 : 1.0 / 32768 + 1e-7)
        expect(err).to be > 1e-6 unless deep # (16 bits really are 16 bits)
      end
    end

    it 'joins linked stereo pairs and pans mono zones' do
      path = font(
        samples: [
          { name: 'L', data: SF2Writer.sine(441, 2000), type: 4, link: 1 },
          { name: 'R', data: SF2Writer.sine(882, 2000), type: 2, link: 0 },
          { name: 'M', data: SF2Writer.sine(441, 2000) },
        ],
        instruments: [{ name: 'I', zones: [
          { key_range: [0, 59], pan: 500, sample_id: 1 },
          { key_range: [0, 59], pan: -500, sample_id: 0 },
          { key_range: [60, 127], pan: -250, sample_id: 2 },
        ] }],
        presets: [{ name: 'P', zones: [{ instrument: 0 }] }]
      )
      inst = m.sf2(path, 0)
      expect(inst.layers).to be_nil
      expect(inst.regions.length).to eq(2)
      st, mono = inst.regions
      expect(st.sample.channel_count).to eq(2)
      expect(st.sample.name).to eq('L + R')
      expect(st.pan).to eq(0)
      expect(mono.pan).to eq(-0.5)
      expect(inst.channel_count).to eq(2)

      l, r = play(inst, m.seq(m::A3.n4, m::C4.n4), 48000)
      expect(freq(l[2000...20000], 48000)).to be_within(1).of(441 * 2**((57 - 60) / 12.0) * 44100 / 44100.0)
      expect(freq(r[2000...20000], 48000)).to be_within(1).of(882 * 2**((57 - 60) / 12.0))
      # C4 plays the mono sample panned left of center (equal power, 0 dB in the middle)
      ratio = r[26000...47000].abs.max / l[26000...47000].abs.max
      angle = (-0.5 + 1) * Math::PI / 4
      expect(ratio).to be_within(0.01).of(Math.tan(angle))
    end

    it 'skips ROM and compressed samples and tolerates missing terminal records, listing what it leaves out' do
      path = font(
        samples: [{ name: 'ok', data: SF2Writer.sine(441, 1000) }, { name: 'rom', data: [0.0] * 10, type: 0x8001 }],
        instruments: [{ name: 'I', zones: [
          { key_range: [0, 59], sample_id: 0, exclusive_class: 1, vib_lfo_to_pitch: 50, freq_vib_lfo: 100, mods: 2 },
          { key_range: [60, 127], sample_id: 1 },
        ] }],
        presets: [{ name: 'P', zones: [{ instrument: 0, chorus_effects_send: 200 }] }],
        terminals: false
      )
      f = m.sf2(path)
      inst = nil
      expect { inst = f.instrument }.to output(/SF2 spec.sf2 000:000 P: not mapped: .*vibrato LFO \(1 zone\).*exclusive class.*modulators.*ROM samples/).to_stderr
      expect(inst.regions.length).to eq(1)
      expect(f.skipped).to eq(
        'vibrato LFO' => 1, 'exclusive class (choke groups)' => 1, 'modulators (only the default velocity-to-attenuation one is mapped)' => 1,
        'zones playing ROM samples (not in the file)' => 1
      )
      expect { f.instrument(name: 'again') }.not_to output.to_stderr # once per preset

      # a file cut short keeps what it has
      bytes = File.binread(sine_font)
      cut = tmp_path('cut.sf2')
      File.binwrite(cut, bytes[0...(bytes.bytesize - 30)])
      expect { m.sf2(cut).presets }.not_to raise_error
    end
  end

  describe 'playing' do
    it 'plays notes at their pitch, loops held notes, and picks velocity layers' do
      path = font(
        samples: [
          { name: 'soft', data: SF2Writer.sine(441, 4410), pitch: 69, loop: [0, 4400] },
          { name: 'loud', data: SF2Writer.sine(441 * 1.5, 4410), pitch: 69, loop: [0, 4400] },
        ],
        instruments: [{ name: 'I', global: { sample_modes: 1, release_vol_env: -6000 }, zones: [
          { vel_range: [0, 99], sample_id: 0 }, { vel_range: [100, 127], sample_id: 1, coarse_tune: 1, fine_tune: -50 },
        ] }],
        presets: [{ name: 'P', zones: [{ instrument: 0 }] }]
      )
      inst = m.sf2(path, 0)
      out = play(inst, m.seq(m::A4.n1.vel(0.5), m::C5.n1.vel(1)), 4 * 48000)[0]
      # the 0.1 s sample loops for the whole 2 s note
      expect(out[90000...95000].abs.max).to be > 0.1
      expect(freq(out[1000...95000])).to be_within(0.1).of(441)
      expect(freq(out[97000...190000])).to be_within(0.1).of(441 * 1.5 * 2**(3 / 12.0) * 2**(0.5 / 12.0))
      # velocity: (velocity)² (the default modulator), at 0.4 × 0 cB
      expect(out[20000...40000].abs.max).to be_within(0.01).of(0.5 * (64 / 127.0)**2)
    end

    it 'shapes notes with the volume envelope and filter of each zone, at any buffer size' do
      path = font(
        samples: [{ name: 'a', data: SF2Writer.sine(441, 4410), pitch: 69, loop: [0, 4400] }],
        instruments: [{ name: 'I', global: { sample_modes: 1, attack_vol_env: -1200, decay_vol_env: 0, sustain_vol_env: 200, release_vol_env: -1200 }, zones: [
          { key_range: [0, 63], sample_id: 0, hold_vol_env: -2400 },
          { key_range: [64, 127], sample_id: 0, attack_vol_env: -12000, initial_filter_fc: 6900, initial_filter_q: 100 },
        ] }],
        presets: [{ name: 'P', zones: [{ instrument: 0 }] }]
      )
      inst = m.sf2(path, 0)
      env = inst.envelope
      expect(env[:release_at]).to eq(3)
      attack = env[:segments][0][1]
      expect(attack).to be_a(m::Sampler::ZoneMap)
      expect(attack[60, 100]).to eq(0.5)
      expect(attack[70, 100]).to eq(0.000977)
      expect(env[:segments][1][1][60, 100]).to eq(0.25)  # hold
      expect(env[:segments][1][1][70, 100]).to eq(0.0)
      expect(env[:segments][2]).to eq([0.1, 0.2, 20.0]) # sustain 20 dB down after 20% of a 1 s 100 dB decay
      expect(env[:segments][3]).to eq([0, 0.5, 100])
      expect(env[:sensitivity]).to be_nil
      expect(inst.filter[:cutoff][70, 100]).to be_within(0.01).of(440 * 2**((6900 - 6900) / 1200.0))
      expect(inst.filter[:cutoff][60, 100]).to eq(described_class::OPEN_CUTOFF)
      expect(inst.filter[:quality][70, 1]).to be_within(1e-6).of(10**((10 - 3.01) / 20))

      clip = m.seq(m::A3.n2, m::A4.n2)
      a = play(inst, clip, 2 * 48000, size: 800)[0]
      b = play(inst, clip, 2 * 48000, size: 129)[0]
      expect((a - b).abs.max).to eq(0)
      # A3: a 0.5 s linear attack, then 0.25 s hold
      expect(a[12000...12500].abs.max / a[30000...30500].abs.max).to be_within(0.03).of(0.5)
      # A4 starts at once, through a resonant lowpass at 440 Hz (a 4 dB peak), sustaining 20 dB down
      expect(a[48000 + 400...48000 + 1400].abs.max).to be > 0.1
      sus = a[48000 + 30000...48000 + 40000].abs.max
      expect(20 * Math.log10(sus / (0.5 * (95 / 127.0)**2))).to be_within(0.3).of(-20 + (10 - 3.01)) # an SVF at its cutoff: Q
    end

    it 'plays overlapping zones as layers' do
      path = font(
        samples: [{ name: 'a', data: SF2Writer.sine(441, 4410), loop: [0, 4400] }, { name: 'b', data: SF2Writer.sine(882, 4410), loop: [0, 4400] }],
        instruments: [
          { name: 'A', zones: [{ sample_modes: 1, sample_id: 0 }] },
          { name: 'B', zones: [{ sample_modes: 1, key_range: [60, 72], release_vol_env: 0, sample_id: 1 }] },
        ],
        presets: [{ name: 'P', zones: [{ instrument: 0 }, { instrument: 1, initial_attenuation: 60 }] }]
      )
      inst = m.sf2(path, 0)
      expect(inst.layers.length).to eq(2)
      expect(inst.to_s).to eq('P (2 regions, 2 layers)')
      expect(inst.layers[1].envelope[:segments].last).to eq([0, 1.0, 100])
      out = play(inst, m.seq(m::C4.n4), 24000)[0]
      one = play(inst.layers[0], m.seq(m::C4.n4), 24000)[0]
      two = play(inst.layers[1], m.seq(m::C4.n4), 24000)[0]
      expect((out - one - two).abs.max).to be < 1e-6
      expect(two.abs.max).to be_within(0.01).of(10**(-24 / 200.0) * one.abs.max)
    end
  end

  describe 'graph documents' do
    let(:io) { MB::Sound::GraphIO }

    it 'reads fonts inside the document directory, prints sf2() calls, and copies fonts into bundles' do
      dir = File.dirname(tmp_path('x'))
      FileUtils.mkdir_p(File.join(dir, 'fonts'))
      FileUtils.cp(sine_font({ sample_modes: 1 }), File.join(dir, 'fonts', 'sine.sf2'))
      doc = <<~DOC
        graph 2, name: "s"
        inputs :midi
        synth(midi, voices: 1) { |v| sf2("fonts/sine.sf2", preset: 0).play(v) }
      DOC
      File.write(File.join(dir, 'ok.mbg.rb'), doc)
      notes = m.seq(m::A4.n8).notes
      g = io.load(File.join(dir, 'ok.mbg.rb'), inputs: { midi: notes })
      expect(g.sample(800).abs.max).to be > 0.05

      File.write(File.join(dir, 'abs.mbg.rb'), doc.sub('fonts/sine.sf2', File.join(dir, 'fonts/sine.sf2')))
      expect { io.load(File.join(dir, 'abs.mbg.rb'), inputs: { midi: m.seq(m::A4.n8).notes }) }.to raise_error(io::LoadError, /relative to the document/)
      File.write(File.join(dir, 'up.mbg.rb'), doc.sub('fonts/sine.sf2', '../sine.sf2'))
      expect { io.load(File.join(dir, 'up.mbg.rb'), inputs: { midi: m.seq(m::A4.n8).notes }) }.to raise_error(io::LoadError)

      font_path = File.join(dir, 'fonts', 'sine.sf2')
      notes = m.seq(m::A4.n8).notes
      graph = m.synth(notes, voices: 1) { |v| m.sf2(font_path, 0).play(v) }
      expect(graph.to_ruby).to include(%{sf2(#{font_path.inspect}, preset: 0).play(v)})
      saved = io.save(File.join(dir, 'out'), graph, name: 'out', bundle: true, inputs: { midi: notes })
      text = File.read(saved)
      expect(text).to match(%r{^asset "assets/sine.sf2", sha256: "\h{64}"$})
      expect(text).to include('sf2("assets/sine.sf2", preset: 0).play(v)')
      back = io.load(saved, inputs: { midi: m.seq(m::A4.n8).notes })
      expect(back.sample(800).abs.max).to be > 0.05
    end
  end
end

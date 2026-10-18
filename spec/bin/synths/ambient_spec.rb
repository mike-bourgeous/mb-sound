RSpec.describe('bin/synths/ambient.rb') do
  before(:all) { require File.expand_path('../../../bin/synths/ambient.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'strikes a bowl at each note-on: its partials ring for seconds, beating, harder with velocity' do
    soft = render_patch(MB::Sound.ambient_bowl_voice(patch_notes([MB::Sound::D3.number, 0, 0.2, 0.3]), space: 0), 6)[0]
    hard = render_patch(MB::Sound.ambient_bowl_voice(patch_notes([MB::Sound::D3.number, 0, 0.2, 1.0]), space: 0), 6)[0]
    expect(peak_hz(seconds(hard, 0.5, 5.5), 60, 2000)).to be_within(2).of(MB::Sound::D3.frequency)
    expect(rms_db(seconds(hard, 5, 6))).to be > rms_db(seconds(hard, 0, 1)) - 20 # still ringing
    expect(rms_db(hard)).to be_within(0.5).of(rms_db(soft) + 20 * Math.log10(1.0 / 0.3))

    # The doublet beats 0.7 apart: the fundamental's envelope swells and fades
    # about every 1.4 s
    env = (0...12).map { |i| rms_db(seconds(hard, 0.5 + i * 0.4, 0.7 + i * 0.4)) }
    expect(env.max - env.min).to be > 3
  end

  it 'plays the rin higher and brighter in its room' do
    rin = render_patch(MB::Sound.ambient_rin_voice(patch_notes([MB::Sound::G4.number, 0, 0.2, 1.0])), 3)
    expect(rin.length).to eq(2)
    expect(peak_hz(seconds(rin[0], 0.5, 2.5), 200, 4000)).to be_within(4).of(MB::Sound::G4.frequency)
  end

  it 'strikes the gong at 55 Hz from D2, following other notes, its shimmer swelling in' do
    d2 = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0), 4)[0]
    expect(peak_hz(seconds(d2, 3, 4), 40, 70)).to be_within(1.5).of(55) # (5% sharp at the stroke, gliding down over 4 s)
    d3 = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D3.number, 0, 4, 1.0]), space: 0), 4)[0]
    expect(peak_hz(seconds(d3, 3, 4), 90, 130)).to be_within(1.5).of(110)

    expect(band_share(seconds(d2, 2.5, 3.5), 2000, 8000)).to be > band_share(seconds(d2, 0, 0.5), 2000, 8000) * 3
  end

  it 'rings the gong\'s shimmer at high partials with ring:' do
    noisy = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0, ring: 0), 4)[0]
    rung = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0), 4)[0]
    # Tonal: the strongest 1% of the 2-6 kHz bins hold more of its power
    peaky = ->(x) {
      s = Numo::Pocketfft.rfft(Numo::DFloat.cast(seconds(x, 2.5, 3.5))).abs**2
      band = s[2000..6000].sort
      band[-(band.length / 100)..].sum / band.sum
    }
    expect(peaky.(rung)).to be > peaky.(noisy) * 3
    expect(rms_db(seconds(rung, 2.5, 3.5))).to be_within(3).of(rms_db(seconds(noisy, 2.5, 3.5)))
  end

  it 'spreads the gong\'s shimmer partials across the stereo field with spread:' do
    wide = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0, ring: 1), 4)
    mono = render_patch(MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0, ring: 1, spread: 0), 4)
    side = ->((l, r)) { rms_db(seconds(l - r, 2.5, 3.5)) - rms_db(seconds(l + r, 2.5, 3.5)) }
    expect(side.(wide)).to be > side.(mono) + 6
    expect(rms_db(seconds(wide[0], 2.5, 3.5))).to be_within(2).of(rms_db(seconds(mono[0], 2.5, 3.5)))
    # (a node, e.g. a knob: the same mix; patches-5)
    seeded = ->(spread) { render_patch(MB::Sound.with_seed(5) { MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0, ring: 1, spread: spread) }, 4) }
    plain = seeded.(MB::Sound::AMBIENT_GONG_SPREAD)
    knobbed = seeded.(MB::Sound::AMBIENT_GONG_SPREAD.constant)
    expect((knobbed[0] - plain[0]).abs.max).to be < 1e-4
    expect((knobbed[1] - plain[1]).abs.max).to be < 1e-4
    low, high = MB::Sound.ambient_gong_shimmer(16).map(&:first).minmax
    expect(low).to be_within(2).of(30)
    expect(high).to be_within(4).of(125)
  end

  it 'moves the gong\'s shimmer up or down with tune: (semitones; a number or a node), the low partials staying' do
    gong = ->(**o) { render_patch(MB::Sound.with_seed(5) { MB::Sound.ambient_gong_voice(patch_notes([MB::Sound::D2.number, 0, 4, 1.0]), space: 0, ring: 1, **o) }, 4)[0] }
    # The shimmer's power-weighted mean frequency above 800 Hz
    centroid = ->(x) {
      s = Numo::Pocketfft.rfft(Numo::DFloat.cast(seconds(x, 2.5, 3.5))).abs**2
      s = s[800..]
      (s * (Numo::DFloat.new(s.length).seq + 800)).sum / s.sum
    }
    base = gong.(tune: 0)
    low = gong.(tune: -12)
    high = gong.(tune: 5)
    expect(MB::Sound::AMBIENT_GONG_TUNE).to eq(-7) # (patches-5; 0 before)
    expect(gong.()).to eq(gong.(tune: -7))
    expect(centroid.(low)).to be < centroid.(base) * 0.75
    expect(centroid.(high)).to be > centroid.(base) * 1.15
    expect(peak_hz(seconds(low, 3, 4), 40, 70)).to be_within(1.5).of(55)
    expect((gong.(tune: -12.constant) - low).abs.max).to be < 1e-4 # (a node, e.g. a knob)
  end

  it 'wears the koto and harp with the tape' do
    notes = -> { patch_notes([MB::Sound::A4.number, 0, 0.5], [MB::Sound::D5.number, 0.5, 1]) }
    new = render_patch(MB::Sound.ambient_koto_voice(notes.(), wear: 0, space: 0), 2)[0]
    old = render_patch(MB::Sound.ambient_koto_voice(notes.(), wear: 1, space: 0), 2)[0]
    expect(peak_db(new)).to be > -40
    expect((old - new).abs.max).to be > 1e-3

    harp = render_patch(MB::Sound.ambient_harp_voice(notes.(), wear: 0.5), 2)
    expect(peak_db(harp[0])).to be > -50
  end

  it 'keeps the tape hiss steady under a fading tail, with its own hiss on each channel (TPDF; textures-5)' do
    t = Numo::DFloat.new(48000 * 6).seq / 48000
    # 220 Hz falling from 0.1 by 12 dB/s: -94 dBFS by the end, far under the grain
    x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 220) * 0.1 * 10.0**(-12 * t / 20))
    tape = MB::Sound.ambient_tape(MB::Sound.stereo(MB::Sound::ArrayInput.new(data: [x]), MB::Sound::ArrayInput.new(data: [x])))
    l, r = render_patch(tape, 6)
    # The grain alone: above 1 kHz (two highpasses)
    grain = ->(c) {
      2.times.reduce(Numo::DFloat.cast(c)) { |y, _| MB::Sound::Filter::Cookbook.new(:highpass, 48000, 1000, quality: 0.7).process(y) }
    }
    gl = grain.(l)
    loud = rms_db(seconds(gl, 0.5, 1.5)) # (the tail at -26..-38 dBFS)
    quiet = rms_db(seconds(gl, 5, 6))    # (the tail at -86..-98 dBFS)
    expect(quiet).to be_within(2).of(loud)
    expect(quiet).to be_within(4).of(-71) # 10 bits at the default wear 0.6 (textures-7; 8.2 bits, -60, before)
    # (textures-4's half-step dither fell to -88 dBFS here)

    # Independent hiss per channel (one transport gate); the same wow
    gr = grain.(r)
    q = ->(c) { seconds(c, 5, 6) }
    corr = (q.(gl) * q.(gr)).sum / Math.sqrt((q.(gl)**2).sum * (q.(gr)**2).sum)
    expect(corr.abs).to be < 0.1
    expect(peak_hz(seconds(l, 0.5, 1.5), 100, 400)).to eq(peak_hz(seconds(r, 0.5, 1.5), 100, 400))
  end

  it 'sets the tape\'s grain depth directly with bits: (wear still sets the lowpass; textures-6)' do
    t = Numo::DFloat.new(48000 * 2).seq / 48000
    x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 220) * 0.003) # (quiet: its leak through the highpasses stays far under 12 bits)
    floor = ->(**opts) {
      out = MB::Sound.with_seed(1) { render_patch(MB::Sound.ambient_tape(MB::Sound::ArrayInput.new(data: [x]), **opts), 2)[0] }
      y = 2.times.reduce(Numo::DFloat.cast(out)) { |y, _| MB::Sound::Filter::Cookbook.new(:highpass, 48000, 1000, quality: 0.7).process(y) }
      rms_db(seconds(y, 0.5, 1.5))
    }
    default = floor.()
    expect(floor.(bits: 10)).to be_within(0.5).of(default) # (wear 0.6 is 10 bits since textures-7)
    expect(floor.(bits: 12)).to be_within(1.5).of(default - 2 * 6.02)
    expect(floor.(bits: 8)).to be_within(1.5).of(default + 2 * 6.02)
  end

  it 'maps tape wear to 12 bits of grain at 0, 10 at 0.6, and 7 at 1, numbers and nodes alike (textures-7)' do
    step = ->(w) { MB::Sound.ambient_tape_step(w) }
    expect(step.(0)).to eq(2.0**-11)
    expect(step.(0.6)).to be_within(1e-15).of(2.0**-9)
    expect(step.(1)).to eq(2.0**-6)
    expect(step.(-1)).to eq(2.0**-11)
    expect(step.(2)).to eq(2.0**-6)

    wears = Numo::DFloat.new(4800).seq / 4799
    numbers = wears.map { |w| step.(w.to_f) }
    expect((numbers[1..-1] - numbers[0..-2]).min).to be > 0 # (rising all the way)

    nodes = render_patch(step.(MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(wears)])), 0.1)[0][0...4800]
    expect((Numo::DFloat.cast(nodes) - numbers).abs.max / numbers.min).to be < 1e-5
  end

  it 'records the koto and harp rooms onto the tape: the hiss goes on through the tail, then the tape stops (textures-5)' do
    harp = render_patch(MB::Sound.ambient_harp_voice(patch_notes([MB::Sound::D4.number, 0, 0.5])), 10)
    # The room's tail sinks under the grain, which stays (textures-4: the
    # room after the tape, its tail fading to the reverb's own floor)
    floor = rms_db(seconds(harp[0], 4, 5))
    expect(rms_db(seconds(harp[0], 5, 6))).to be_within(2).of(floor)
    expect(floor).to be_between(-76, -66) # (10 bits at wear 0.6 since textures-7; -55..-65 at 8.2 bits)
    # A second after the room falls under -90 dB, the hiss fades out
    expect(rms_db(seconds(harp[0], 8, 10))).to be < -120
  end

  it 'runs one tape transport for both channels: the hiss stops when both are silent (textures-5)' do
    x = Numo::SFloat.zeros(48000 * 3)
    x[0...24000] = 0.1 # the left sounds for 0.5 s
    y = Numo::SFloat.zeros(48000 * 3)
    y[48000...72000] = 0.1 # the right from 1 s to 1.5 s
    l, r = MB::Sound.with_seed(2) { render_patch(MB::Sound.ambient_tape(MB::Sound.stereo(MB::Sound::ArrayInput.new(data: [x]), MB::Sound::ArrayInput.new(data: [y]))), 4) }
    # The left's hiss goes on while the right sounds (per channel gates would stop it at 1.5 s)
    expect(rms_db(seconds(l, 1.6, 2.4))).to be_between(-76, -66) # (10 bits)
    expect(rms_db(seconds(l, 2.9, 3))).to be < -120
    expect(rms_db(seconds(r, 2.9, 3))).to be < -120
    expect(l.length).to eq(3 * 48000)
  end

  it 'stops the tape a second after its input falls silent, and ends after its input ends (textures-5)' do
    x = Numo::SFloat.zeros(48000 * 2)
    x[0...24000] = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(24000).seq * (2 * Math::PI * 220 / 48000)) * 0.1)
    o = MB::Sound.with_seed(2) { render_patch(MB::Sound.ambient_tape(MB::Sound::ArrayInput.new(data: [x])), 4)[0] }
    expect(rms_db(seconds(o, 0.6, 1.4))).to be_between(-76, -66)   # hiss held for a second (10 bits)
    expect(rms_db(seconds(o, 1.9, o.length / 48000.0))).to be < -120 # stopped
    # The input ends at 2 s, long after it fell silent: the tape ends at once
    expect(o.length).to be_between(2 * 48000, 2 * 48000 + 800)

    # The same samples at any buffer size, through the same edges (sound
    # to silence, the hold's end, the fade, the stop, the input's end) on
    # a shorter tape (stop: 0.25 s; test-speed-3: one-sample buffers over
    # the 2 s tape took 7.5 s)
    short = Numo::SFloat.zeros(38400)
    short[0...6000] = x[0...6000]
    out = [1, 128, 800].to_h { |bs|
      [bs, MB::Sound.with_seed(2) { render_patch(MB::Sound.ambient_tape(MB::Sound::ArrayInput.new(data: [short]), stop: 0.25), 1, buffer: bs)[0] }]
    }
    expect(out[800].length).to be_between(38400, 38400 + 800)
    expect(rms_db(seconds(out[800], 0.15, 0.35))).to be_between(-76, -66) # held
    expect(rms_db(seconds(out[800], 0.7, 0.8))).to be < -120               # stopped
    expect(out[1]).to eq(out[800])
    expect(out[128]).to eq(out[800])
  end

  it 'drones on the note: root, fifth, and octave' do
    out = render_patch(MB::Sound.ambient_drone_voice(patch_notes([MB::Sound::D2.number, 0, 6])), 6)
    expect(out.length).to eq(2)
    x = seconds(out[0], 3, 6)
    expect(peak_hz(x, 50, 90)).to be_within(1).of(MB::Sound::D2.frequency)
    expect(peak_hz(x, 100, 120)).to be_within(1).of(MB::Sound::A2.frequency)
    expect(peak_hz(x, 140, 160)).to be_within(1).of(MB::Sound::D3.frequency)
    expect(rms_db(seconds(out[0], 0, 0.3))).to be < rms_db(seconds(out[0], 3, 4)) - 10 # a slow swell
  end

  it 'tips the rain stick from right to left over the note' do
    l, r = render_patch(MB::Sound.ambient_rainstick_voice(patch_notes([MB::Sound::D5.number, 0, 8])), 9)
    early = rms_db(seconds(r, 1, 2)) - rms_db(seconds(l, 1, 2))
    late = rms_db(seconds(r, 6, 7)) - rms_db(seconds(l, 6, 7))
    expect(early).to be > 3
    expect(late).to be < -3
  end

  it 'renders the gong from a MIDI file with -p gong' do
    out_file = tmp_path('ambient_gong.flac')
    out, status = fork_script('bin/synths/ambient.rb', '-q', '-p', 'gong', '-s', '0.2', 'spec/test_data/c_major.mid', out_file)
    expect(status).to be_success, out
    expect(MB::Sound.read(out_file)[0].abs.max).to be > 0.01
  end
end

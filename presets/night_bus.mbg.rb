# mb-sound set document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "night_bus",
  kind: :set,
  saved: "2026-10-18T18:40:07Z",
  mb_sound: "0.12.0.usegit (c53e4bb5)",
  from: "bin/songs/night_bus_flow.rb",
  description: "Set :night_bus from bin/songs/night_bus_flow.rb (\"Night Bus: Last Stop\", tech house at 126 BPM in A minor): drums, sub, bass, hooks, plucks, pad, riser; scenes intro..outro; knobs :cut, :space, :echo, :air, :morph; its flow (play_form doc.form).  `demo` loads it."
knob :cut, 700.0, range: 200.0..6000.0, curve: :exp, unit: "Hz"
knob :space, 0.35
knob :echo, 0.35, range: 0.0..0.85
knob :air, 20.0, range: 20.0..400.0, curve: :exp, unit: "Hz"
knob :morph, 0.0

bpm 126
hook = seq(Rest, Rest, E5, Rest, C5, Rest, Rest, A4, Rest, Rest, B4, Rest, C5, Rest, A4, Rest, Rest, Rest, F5, Rest, D5, Rest, Rest, A4, Rest, Rest, C5, Rest, D5, Rest, A4, Rest, Rest, Rest, D5, Rest, B4, Rest, Rest, G4, Rest, Rest, A4, Rest, B4, Rest, G4, Rest, Rest, Rest, F5, Rest, C5, Rest, Rest, A4, Rest, Rest, B4, Rest, C5, Rest, A4, Rest).n16.loop(align: :launch).named(:hook)
hook_hi = hook.transpose(12).named(:hook_hi)
sub = seq(Rest, A1, Rest, A1, Rest, A1, Rest, A1).n8.loop(align: :launch).named(:sub)
roll = seq(Rest, Rest, !A1, A1, Rest, Rest, A1, Rest, Rest, Rest, !A1, A1, Rest, C2, Rest, G1).n16.swing(0.54).loop(align: :launch).named(:roll)
root_hook = seq(Rest, Rest, !A1, Rest, A1, Rest, Rest, A2, Rest, Rest, A1, Rest, A1, Rest, A2, Rest).n16.loop(align: :launch).named(:root_hook)
tension = seq(E5, Tie, Tie, Tie, Tie, Tie, Tie, Tie).n1.loop(align: :launch).named(:tension)
arp = seq(A5, C6, E6, B5).n16.loop(align: :launch).named(:arp)
pad = seq(A2, A2, A2, G2).n1.legato(0.98).loop(align: :launch).named(:pad)
bar = seq(Rest).n1.loop.named(:bar)
kit = grid(16, kick: "X...x...X...x...", clap: "....X.......X...", hat: "..x...x...x...x.", open_hat: "................", shaker: "3735373537353735", ride: "................", crash: "................", low_tom: "................")
kit_intro = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_intro)
kit = grid(16, kick: "X...x...X...x...", clap: "....X.......X...", hat: "..x...x...x...x.", open_hat: "..x.......x.....", shaker: "3735373537353735", ride: "................", crash: "................", low_tom: "................")
kit_groove = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_groove)
kit = grid(16, kick: "x...x...x...x...", clap: "................", hat: "..x...x...x...x.", open_hat: "................", shaker: "................", ride: "................", crash: "................", low_tom: "................")
kit_build = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_build)
kit = grid(16, kick: "X...x...X...x...", clap: "....X.......X...", hat: "..X...X...X...X.", open_hat: "................", shaker: "3735373537353735", ride: "................", crash: "X...............", low_tom: "................")
kit_drop = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_drop)
kit = grid(16, kick: "X...x...X...x...", clap: "....X.......X...", hat: "..X...X...X...X.", open_hat: "................", shaker: "3735373537353735", ride: "6.4.6.4.6.4.6.4.", crash: "X...............", low_tom: "................")
kit_pickup = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_pickup)
kit = grid(16, kick: "................", clap: "....X.......X...", hat: "..x...x...x...x.", open_hat: "................", shaker: "3735373537353735", ride: "................", crash: "................", low_tom: "................")
kit_cut = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_cut)
kit = grid(16, kick: "X...x...X...x...", clap: "................", hat: "..x...x...x...x.", open_hat: "................", shaker: "................", ride: "................", crash: "................", low_tom: "................")
kit_outro = Sequence::Kit.new({ kick: kit[:kick], clap: kit[:clap], hat: kit[:hat].swing(0.54), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.54), ride: kit[:ride].swing(0.54), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:clap, :open_hat, name: :turn).fill(:turn, clap: grid(16, "....X...x.x.xXXX", value: 39)).fill(:toms, low_tom: grid(16, "..........x..x.x", value: 45)).loop(align: :launch).named(:kit_outro)
master(:streaming, lufs: :apple_music) { |mix|
  mix.filter(:highpass, cutoff: air, quality: 0.8).softclip(0.5, 0.97)
}
track(:drums) { |kit|
  tr808(kit, kick: { tune: 50, decay: 0.5, tone: 0.4 }, clap: { decay: 0.25, tone: 0.6 }, closed_hat: { decay: 0.04 }, open_hat: { decay: 0.25 }, cymbal: { decay: 0.9, tone: 0.65 }, maracas: { level: 0.22 }, low_tom: { decay: 0.6 }, accent: 6.db, seed: drawn_seed(3969543146641149120)) * 0.85
}
track(:sub) { |clip|
  synth(clip, voices: 1) { |n|
    n.freq.tone * n.env(0.004, 0.09, 0.8, 0.05, gm: false)
  } * 0.32
}
track(:bass) { |clip|
  synth(clip, voices: 1) { |n|
    bump = n.env(0.0005, 0.03, 0, 0.02, curve: :linear, gm: false)
    freq = n.freq * (bump * 0.45 + 1)
    fenv = n.env(0.001, 0.06, 0, 0.04, gm: false)
    amp = n.env(0.001, 0.2, 0, 0.05, gm: false) * (n.velocity * 0.4 + 0.6)
    saw = freq.tone.saw.lp4(2 ** (fenv * 2.5) * 240, resonance: 0.35)
    ((saw + freq.tone * 0.6) * amp).softclip(0.7, 0.97)
  } * 1.4
}
track(:hook) { |clip|
  (synth(clip, voices: 1) { |n|
    pitch = n.hz.glide(0.025, legato: true)
    src = pitch.pwm(0.16) * 0.6
    vowel = 0.31.hz.lfo.triangle * 0.5 + 0.5
    body = src.lp4(cut, resonance: 0.5)
    f1 = src.filter(:bandpass, cutoff: vowel * 500 + 650, quality: 5)
    f2 = src.filter(:bandpass, cutoff: vowel * 900 + 1500, quality: 6)
    voice = body + f1 * 1.4 + f2 * 1.1
    rate = 2 ** ((n.number - 69) / 24.0) * 9000
    crushed = voice.sample_hold(rate.tone.asquare)
    amp = n.env(0.004, 0.22, 0.45, 0.09, gm: false)
    (crushed * amp * 4).peq(3500.hz => [3.db, 0.8]).filter(:highpass, cutoff: 220, quality: 0.7)
  } * 0.25).delay(1.n8.dotted, feedback: echo, wet: space, dry: 1).softclip(0.5, 0.95) * 0.8
}
track(:hook_far) { |clip|
  (synth(clip, voices: 1) { |n|
    pitch = n.hz.glide(0.025, legato: true)
    src = pitch.pwm(0.16) * 0.6
    vowel = 0.31.hz.lfo.triangle * 0.5 + 0.5
    body = src.lp4(cut, resonance: 0.5)
    f1 = src.filter(:bandpass, cutoff: vowel * 500 + 650, quality: 5)
    f2 = src.filter(:bandpass, cutoff: vowel * 900 + 1500, quality: 6)
    voice = body + f1 * 1.4 + f2 * 1.1
    rate = 2 ** ((n.number - 69) / 24.0) * 9000
    crushed = voice.sample_hold(rate.tone.asquare)
    amp = n.env(0.004, 0.22, 0.45, 0.09, gm: false)
    (crushed * amp * 4).peq(3500.hz => [3.db, 0.8]).filter(:highpass, cutoff: 220, quality: 0.7)
  } * 0.15).delay(1.n8.dotted, feedback: 0.35, wet: 0.35, dry: 1).softclip(0.5, 0.95) * 0.8
}
track(:hook_rise) { |clip|
  (synth(clip, voices: 1) { |n|
    pitch = n.hz.glide(0.025, legato: true)
    src = pitch.pwm(0.16) * 0.6
    vowel = 0.31.hz.lfo.triangle * 0.5 + 0.5
    body = src.lp4(cut, resonance: 0.5)
    f1 = src.filter(:bandpass, cutoff: vowel * 500 + 650, quality: 5)
    f2 = src.filter(:bandpass, cutoff: vowel * 900 + 1500, quality: 6)
    voice = body + f1 * 1.4 + f2 * 1.1
    rate = 2 ** ((n.number - 69) / 24.0) * 9000
    crushed = voice.sample_hold(rate.tone.asquare)
    amp = n.env(0.004, 0.22, 0.45, 0.09, gm: false)
    (crushed * amp * 4).peq(3500.hz => [3.db, 0.8]).filter(:highpass, cutoff: 220, quality: 0.7)
  } * 0.2).delay(1.n8.dotted, feedback: 0.35, wet: 0.35, dry: 1).softclip(0.5, 0.95) * 0.8
}
track(:hook_wash) { |clip|
  (synth(clip, voices: 1) { |n|
    pitch = n.hz.glide(0.025, legato: true)
    src = pitch.pwm(0.16) * 0.6
    vowel = 0.31.hz.lfo.triangle * 0.5 + 0.5
    body = src.lp4(cut, resonance: 0.5)
    f1 = src.filter(:bandpass, cutoff: vowel * 500 + 650, quality: 5)
    f2 = src.filter(:bandpass, cutoff: vowel * 900 + 1500, quality: 6)
    voice = body + f1 * 1.4 + f2 * 1.1
    rate = 2 ** ((n.number - 69) / 24.0) * 9000
    crushed = voice.sample_hold(rate.tone.asquare)
    amp = n.env(0.004, 0.22, 0.45, 0.09, gm: false)
    (crushed * amp * 4).peq(3500.hz => [3.db, 0.8]).filter(:highpass, cutoff: 220, quality: 0.7)
  } * 0.4).delay(1.n8.dotted, feedback: 0.55, wet: 0.55, dry: 1).softclip(0.5, 0.95) * 0.45
}
track(:answer) { |clip|
  clip.synth(voices: 3, seed: drawn_seed(3941382327821454732)) { |v|
    fx = v.velocity.aease(:quad_out, out: 0.0..1.0)
    sig = v.freq
    sig2 = v.period
    fx2 = sig.aease(:smoothstep, in: 707.1067811865474..1414.213562373095)
    sig3 = 1 - fx
    sig4 = fx2 + (1 - fx2) * sig3
    osc = noise
    osc2 = noise
    sig5 = osc2.filter(:lowpass, cutoff: 1500 * 7.0.constant ** fx, quality: 0.6) * v.env(0, 0.008, 0, 0.008, gm: false, sensitivity: 0.3..1.0) * (((1200.0 / sig) ** 0.531508495181978).aclip(1, 100) * 2.8.db) * ((1 - fx2) * fx ** 0.5)
    sig6 = 10.constant ** (-3.333333333333333 / sig)
    sig7 = sig * (6.0 - 4.0 * v.cc(1, range: 0.0..1.0, name: "Damping", description: "Darkens the string (loop lowpass)"))
    (osc.filter(:lowpass, cutoff: sig * 10.0.constant ** fx, quality: 0.6) * v.env(0, 0, 1, 0, gate: false, gm: false, hold: sig2 * 1.0, sensitivity: 0.3..1.0) * (fx2 + (1 - fx2) * sig3 ** 0.5)).feedback { |fb, input|
      line = fb + input
      d = line.delay(sig2, smooth: false, max_delay: 0.08)
      s = ((d + d.delay(1.samples)) * (sig6 * 0.5)).filter(:lowpass, cutoff: sig7, quality: 0.7071067811865476)
      s + sig5
    } * v.amp_env([[0, sig2 * sig4, 0, :exp], [1, sig2 * (sig4 + 1), 0, :exp], [0, 0.08]]) * 4
  }.delay(1.n8.dotted, feedback: 0.3, wet: 0.35, dry: 1) * 0.26
}
track(:arp) { |clip|
  clip.synth(voices: 3, seed: drawn_seed(2461561594657129153)) { |v|
    fx = v.velocity.aease(:quad_out, out: 0.0..1.0)
    sig = v.freq
    sig2 = v.period
    fx2 = sig.aease(:smoothstep, in: 707.1067811865474..1414.213562373095)
    sig3 = 1 - fx
    sig4 = fx2 + (1 - fx2) * sig3
    osc = noise
    osc2 = noise
    sig5 = osc2.filter(:lowpass, cutoff: 1500 * 7.0.constant ** fx, quality: 0.6) * v.env(0, 0.008, 0, 0.008, gm: false, sensitivity: 0.3..1.0) * (((1200.0 / sig) ** 0.531508495181978).aclip(1, 100) * 2.8.db) * ((1 - fx2) * fx ** 0.5)
    sig6 = 10.constant ** (-3.333333333333333 / sig)
    sig7 = sig * (6.0 - 4.0 * v.cc(1, range: 0.0..1.0, name: "Damping", description: "Darkens the string (loop lowpass)"))
    (osc.filter(:lowpass, cutoff: sig * 13.0.constant ** fx, quality: 0.6) * v.env(0, 0, 1, 0, gate: false, gm: false, hold: sig2 * 1.0, sensitivity: 0.3..1.0) * (fx2 + (1 - fx2) * sig3 ** 0.5)).feedback { |fb, input|
      line = fb + input
      d = line.delay(sig2, smooth: false, max_delay: 0.08)
      s = ((d + d.delay(1.samples)) * (sig6 * 0.5)).filter(:lowpass, cutoff: sig7, quality: 0.7071067811865476)
      s + sig5
    } * v.amp_env([[0, sig2 * sig4, 0, :exp], [1, sig2 * (sig4 + 1), 0, :exp], [0, 0.08]]) * 4
  }.delay(1.n8.dotted, feedback: 0.3, wet: 0.35, dry: 1) * 0.136
}
track(:tension) { |clip|
  synth(clip, voices: 1) { |n|
    (n.freq * (5.hz.lfo.sine * 0.004 + 1)).tone.triangle.filter(:lowpass, cutoff: 2500) * n.env(1.5, 0.1, 1.0, 1.2, gm: false)
  } * 0.09
}
track(:pad, lead: 0.5.attack) { |clip|
  fx = clip.synth(voices: 2) { |v|
    swell = v.amp_env(0.6, 1.0, 0.8, 2, sensitivity: -6.db..0.db, curve: :smooth)
    bloom = v.filter_env(0.8999999999999999, 2.0, 0.43, 2, depth: 1.584962500721156, curve: [6, 0, -6], shape: :s)
    sig = v.hz
    sig2 = sig.transpose(7)
    ((sig.saw.at(0.5) + sig.transpose(0.07).saw.at(0.5) + (sig2.saw.at(0.5) + sig2.transpose(0.07).saw.at(0.5)) * 0.7) * swell * 0.35).filter(:lowpass, cutoff: v.cutoff(450.0, env: bloom, keytrack: 0), quality: 0.9)
  }.softclip(0.4, 0.9)
  stereo(fx, fx.delay(0.012)) * 0.25
}
track(:riser, fade: 1r/8) { |_clip|
  noise(seed: drawn_seed(1255200654889945937)).filter(:highpass, cutoff: tween([250, 8000], 4.bars, log: true, loop: false), quality: 3) * tween([0.06, 0.12], 4.bars, loop: false)
}
scene :intro, drums: kit_intro
scene :groove, drums: kit_groove, sub: sub, hook_far: hook, cut: 700
scene :build, drums: kit_build, tension: tension, hook_rise: hook, cut: [3200, { from: 500, over: 8, curve: :smooth }]
scene(:gap) { meter 2, 4 }
scene(:drop, drums: kit_drop, bass: roll, hook: hook, cut: 2600, space: 0.35, echo: 0.35, air: 20) { meter 4, 4 }
scene :pickup, drums: kit_pickup, bass: roll, hook: hook, answer: hook_hi, pad: pad
scene :breakdown, drums: kit_cut, hook_wash: hook, pad: pad, cut: [2600, { from: 900, over: 8, curve: :smooth }], air: [200, { over: 1.beat }]
scene :lift, drums: kit_cut, hook_wash: hook, arp: arp, pad: pad
scene :drop2, drums: kit_drop, bass: root_hook, arp: arp, air: 20
scene :pickup2, drums: kit_pickup, bass: root_hook, arp: arp, pad: pad
scene :outro, drums: kit_outro, hook_far: hook
scene :riser, riser: bar, others: :keep
flow do
  fill :turn, every: 8
  fill :toms, every: 4
  intro 8
  groove 8
  build 8, fill: [:riser, 4]
  gap 1
  drop 8
  pickup 8
  pick do |p|
    p.option(3) { }
    p.option(1) do
      drop
      pickup
    end
  end
  breakdown 8
  lift 8, fill: [:riser, 4]
  label :rolling
  drop2 8
  pickup2 8
  goto :rolling
  outro 8
end

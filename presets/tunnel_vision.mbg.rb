# mb-sound set document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "tunnel_vision",
  kind: :set,
  saved: "2026-10-18T05:50:07Z",
  mb_sound: "0.12.0.usegit (0e9d7ce1)",
  from: "bin/songs/tunnel_vision.rb",
  description: "Set :tunnel_vision from bin/songs/tunnel_vision.rb (\"Tunnel Vision\", Kez Volta's drum & bass at 174 BPM in F minor, the buses demo): drums, Reese, sub, neuro, boom, riser, pad, pluck; a :hall bus (ducked by the kick) and an :echo bus with sends, the basses ducked by the drums' kick voice; scenes intro..tail; knobs :cut, :grit, :space, :air, :lift; its flow (play_form doc.form).  `demo :tunnel_vision` loads it."
knob :cut, 2400.0, range: 150.0..8000.0, curve: :exp, unit: "Hz"
knob :grit, 0.25
knob :space, 0.4
knob :air, 20.0, range: 20.0..400.0, curve: :exp, unit: "Hz"
knob :lift, 1.0

bpm 174
master_gain 1.0
riff = seq(F1, Tie, Tie, Tie, Tie, Tie, Rest, F1, Tie, Rest, Gs1, Tie, F1, Tie, Rest, Rest, F1, Tie, Tie, Tie, Tie, Tie, Rest, C2, Tie, Rest, As1, Tie, Gs1, Tie, Ds1, Tie).n16.loop(align: :launch).named(:riff)
neuro = seq(F1, Rest, F1, F1, Rest, F1, Rest, F1, Tie, Rest, Gs1, Rest, F1, F1, Rest, Ds1, F1, Rest, F1, F1, Rest, F1, Rest, C2, Tie, Rest, As1, Gs1, Rest, Gs1, Ds1, Tie).n16.loop(align: :launch).named(:neuro)
pad = seq(F2.n1, Cs2.n1, As1.n1, C2.n1).bake(chord(0, 7, 15, 19, 26)).legato(0.97).loop(align: :launch).named(:pad)
pluck = seq(C5, Gs4, F4, Ds5, Rest, C5, Gs4, G4).n8.ghost_chords(1, 6, 4, 5, scale: scale(:minor, F4)).loop(align: :launch).named(:pluck)
boom = seq(F1, Rest, Rest, Rest, Rest, Rest, Rest, Rest).n1.loop(align: :launch).named(:boom)
bar = seq(Rest).n1.loop.named(:bar)
kit = grid(16, kick: "X.........X.....", snare: "................", clap: "................", rim: "....6.......6...", hat: "7.4.7.4.7.4.7.45", open_hat: "................", shaker: "3524352435243524", crash: "................", low_tom: "................")
kit_intro = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).loop(align: :launch).named(:kit_intro)
kit = grid(16, kick: "X.........X.....", snare: "....X..2.2..X..2", clap: "................", rim: "................", hat: "7.4.7.4.7.4.7.45", open_hat: "..5...5...5...5.", shaker: "3524352435243524", crash: "................", low_tom: "................")
kit_build = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:snare, :clap, :open_hat, name: :roll).fill(:roll, snare: grid(16, "2.3.4.5.5656778X"), low_tom: grid(16, "............5.7.")).loop(align: :launch).named(:kit_build)
kit = grid(16, kick: "X.........X.....", snare: "....X..2.2..X..2", clap: "....X.......X...", rim: "................", hat: "7.4.7.4.7.4.7.45", open_hat: "..4.......4.....", shaker: "3524352435243524", crash: "X...............", low_tom: "................")
kit_drop = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:snare, :clap, :open_hat, name: :roll).fill(:roll, snare: grid(16, "2.3.4.5.5656778X"), low_tom: grid(16, "............5.7.")).loop(align: :launch).named(:kit_drop)
kit = grid(16, kick: "................", snare: "................", clap: "................", rim: "................", hat: "4.2.4.2.4.2.4.2.", open_hat: "................", shaker: "3524352435243524", crash: "................", low_tom: "................")
kit_breakdown = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).loop(align: :launch).named(:kit_breakdown)
kit = grid(16, kick: "X.........X.....X.........X..x..", snare: "....X.2..2..X.2.....X..2.2.2X..3", clap: "....X.......X.......X.......X...", rim: "................", hat: "7.4.7.4.7.4.7.45", open_hat: "..4.......4.....", shaker: "3524352435243524", crash: "X...............", low_tom: "................")
kit_drop2 = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).nofill(:snare, :clap, :open_hat, name: :roll).fill(:roll, snare: grid(16, "2.3.4.5.5656778X"), low_tom: grid(16, "............5.7.")).loop(align: :launch).named(:kit_drop2)
kit = grid(16, kick: "X.........X.....", snare: "....X.......X...", clap: "................", rim: "................", hat: "7.4.7.4.7.4.7.45", open_hat: "................", shaker: "3524352435243524", crash: "................", low_tom: "................")
kit_outro = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).loop(align: :launch).named(:kit_outro)
kit = grid(16, kick: "X.........X.....", snare: "................", clap: "................", rim: "................", hat: "7.4.7.4.7.4.7.45", open_hat: "................", shaker: "................", crash: "................", low_tom: "................")
kit_tail = Sequence::Kit.new({ kick: kit[:kick], snare: kit[:snare], clap: kit[:clap], rim: kit[:rim], hat: kit[:hat].swing(0.52), open_hat: kit[:open_hat], shaker: kit[:shaker].swing(0.52), crash: kit[:crash].every(8), low_tom: kit[:low_tom] }).loop(align: :launch).named(:kit_tail)
master { |mix|
  (mix.filter(:highpass, cutoff: air, quality: 0.7).compress(threshold: -14.db, ratio: 2, knee: 6, attack: 0.01, release: 0.12) * 11.0.db).softclip(0.6, 1.0).limit(ceiling: -0.5.db, release: 0.06)
}
bus(:hall) { |sig|
  wet = sig.filter(:highpass, cutoff: 250, quality: 0.7).reverb(:hall, mix: 1) * 18.0.db
  lifted = wet.compress(threshold: 0.db, ratio: 1, upward_threshold: -36.db, upward_ratio: 4, max_gain: 12.db, attack: 0.01, release: 0.15, upward_attack: 0.02, detector: :rms, rms: 0.05)
  (wet * (lift * -1 + 1) + lifted * (lift * -6.db)).duck(:drums, only: :kick, amount: -6.db, release: 1.n8)
}
bus(:echo) { |sig|
  sig.delay(1.n8.dotted, feedback: 0.4)
}
track(:pad, send: { hall: 0.35 }) { |clip|
  synth(clip, voices: 10) { |v|
    saws = v.hz.unison(3, detune: 0.12) { |p, _i|
      p.saw
    }
    saws.lp4(2600, resonance: 0.1) * v.env(0.6, 0.5, 0.8, 1.2, gm: false) * 0.25
  }.filter(:highpass, cutoff: 200, quality: 0.7) * 0.39
}
track(:pluck, send: { echo: :space, hall: 0.25 }) { |clip|
  synth(clip, voices: 2) { |v|
    fenv = v.env(0.001, 0.18, 0.0, 0.1, gm: false)
    tone = v.hz.square.lp4(500 * 2 ** (fenv * 3), resonance: 0.3)
    tone * v.env(0.002, 0.35, 0.0, 0.15, gm: false) * 0.5
  } * 0.3375
}
track(:drums, send: { hall: -24.db }) { |kit|
  tr808(kit, kick: { tune: 54, decay: 0.38, tone: 0.62, sigh: 0.9 }, snare: { tune: 205, decay: 0.2, snappy: 0.8, tone: 0.8, level: 0.95 }, clap: { decay: 0.16, tone: 0.8, level: 0.5 }, rimshot: { level: 0.35 }, closed_hat: { decay: 0.035, tone: 0.85, level: 0.55 }, open_hat: { decay: 0.16, tone: 0.7, level: 0.25 }, cymbal: { decay: 1.4, tone: 0.7, level: 0.3 }, maracas: { level: 0.25 }, low_tom: { tune: 120, decay: 0.35 }, accent: 6.db).compress(threshold: -24.db, ratio: 4, attack: 0.002, release: 0.06, makeup: 9.db, mix: 0.35)
}
track(:reese, send: { hall: 0.1 }) { |clip|
  (synth(clip, voices: 1) { |v|
    pitch = v.hz.glide(0.035, legato: true)
    saws = pitch.unison(6, detune: 0.32, spread: 0.5) { |p, _i|
      p.saw
    }
    lfo = 2 ** v.lfo(2.bars, shape: :sine, depth: 0.8)
    amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
    ((saws.lp4(cut * lfo, resonance: 0.25) * 2.2).softclip(0.35, 0.95) * amp).filter(:highpass, cutoff: 150, quality: 0.7).filter(:highpass, cutoff: 150, quality: 0.7)
  } * 1.0).duck(:drums, only: :kick, amount: -8.db, release: 1.n16)
}
track(:sub) { |clip|
  (synth(clip, voices: 1) { |v|
    pitch = v.hz.glide(0.035, legato: true)
    env = v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato
    upper = pitch.transpose(12).sine * 0.2 + pitch.transpose(19.019550008653873).sine * 0.1
    ((pitch.sine * env).filter(:lowpass, cutoff: 110, quality: 0.7) + upper * env) * 0.9759000729485331
  } * 0.5).duck(:drums, only: :kick, amount: -12.db, release: 1.n16)
}
track(:neuro, send: { hall: 0.1 }) { |clip|
  (synth(clip, voices: 1) { |v|
    pitch = v.hz.glide(0.02, legato: true)
    sig = pitch.unison(3, detune: 0.18) { |p, _i|
      p.saw
    }
    src = sig + pitch.transpose(12).square * 0.4
    lfo = v.lfo(1.n16, shape: :square, depth: 1.3)
    jump = 2 ** lfo
    ladder = src.diode(600 * jump * 2 ** (v.env(0.002, 0.12, 0.6, 0.04, gm: false).legato * 2), resonance: 0.55)
    ratio = (v.env(0.002, 0.12, 0.6, 0.04, gm: false).legato * 4 + lfo * 1.5 + 3.5).aclip(2, 9)
    buzz = (pitch.pulse(0.3) + 1) * 0.5
    osc = noise
    talk = ladder.formant(:o, :a, :i, voice: :bass, morph: v.lfo(1.n8, shape: :triangle, unipolar: true) * 2) + pitch.saw.sync(nil, ratio: ratio).filter(:highpass, cutoff: 1200, quality: 0.7).filter(:lowpass, cutoff: 14000, quality: 0.7) * 0.16000000000000003 + osc.filter(:highpass, cutoff: 3000, quality: 0.7) * buzz * 0.15
    crushed = (talk * 3).softclip(0.3, 0.95).decimate(v.freq * 24, mix: grit)
    env = v.env(0.002, 0.12, 0.6, 0.04, gm: false).legato
    crushed * env
  }.squeeze(:default, depth: 0.7, split: [250, 2500]).filter(:highpass, cutoff: 140, quality: 0.7) * 0.85).duck(:drums, only: :kick, amount: -8.db, release: 1.n16)
}
track(:boom, send: { hall: 0.1 }) { |clip|
  synth(clip, voices: 1) { |n|
    dive = n.env(0, 0.25, 0, 0.1, curve: :linear, gm: false)
    ((n.freq * 2 ** (dive * 2)).tone * n.env(0.001, 1.2, 0, 0.3, gm: false) * 1.4).softclip(0.5, 0.95)
  }.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.4
}
track(:riser, fade: 1r/8, send: { hall: -18.db }) { |_clip|
  noise.filter(:bandpass, cutoff: tween([250, 10000], 8.bars, log: true, loop: false), quality: 3) * tween([0.03, 0.25], 8.bars, loop: false)
}
scene :intro, drums: kit_intro, pad: pad, reese: bar, neuro: bar, cut: 250, air: 20
scene :build, drums: kit_build, reese: riff, neuro: bar, cut: [2500, { from: 250, over: 8, curve: :smooth }]
scene :drop, drums: kit_drop, reese: riff, sub: riff, neuro: bar, boom: boom, cut: 2400, air: 20
scene :breakdown, drums: kit_breakdown, pad: pad, pluck: pluck, reese: bar, neuro: bar, air: [180, { over: 1.beat }]
scene :pullup, riser: bar, reese: bar, neuro: bar
scene :drop2, drums: kit_drop2, neuro: neuro, sub: riff, reese: bar, boom: boom, air: 20, grit: 0.25
scene :drop2b, drums: kit_drop2, neuro: neuro, sub: riff, reese: riff, cut: 1600, grit: [0.6, { over: 8 }]
scene :outro, drums: kit_outro, sub: riff, reese: bar, neuro: bar
scene :tail, drums: kit_tail
scene :riser, riser: bar, others: :keep
flow do
  fill :roll, every: 16
  intro 16
  build 8, fill: [:riser, 4]
  drop 32
  breakdown 15, fill: [:riser, 8]
  pullup 1
  drop2 16
  drop2b 8
  outro 8
  tail 8
end

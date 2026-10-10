#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Night Bus: Last Stop": the Night Bus set grown into a song form (phase 2
# of the arrangement tools; phase 1 is night_bus_set.rb).  A tech house
# track at 126 BPM in A minor, about 89 bars, built as one strong loop and
# arranged mostly by adding and removing parts in 8-bar blocks.  The form is
# written once as a `flow` block; the performer steers it live with loop!,
# onward, and finish, and a weighted follow action decides what comes after
# the first drop.
#
#   intro     8  drums only: tight kick, late-feeling clap, offbeat hats,
#                a soft/accented shaker; a clap/tom turnaround every 8 bars
#   groove    8  the hook enters through a low lowpass, offbeat sub on the
#                root; the performer types `loop!` (it plays twice), then
#                `onward`
#   build     8  thinned drums, one held E5 for tension, the hook opening out
#                of its filter; a noise riser in the last 4 bars (a fill)
#   gap       1  one 2/4 bar: everything rings out (scene drops ring by
#                default) for a half-bar breath; `meter 2, 4` in its scene
#   drop      8  dry: kick, punchy saw bass rolling against the kick, the
#                vocal-ish hook unfiltered, a crash on the downbeat
#   pickup    8  ride and an octave pluck answer the hook, a static pad;
#                next: { breakdown: 3, drop: 1 } (a seeded chance branch)
#   breakdown 8  low end cut on the master (highpass "cut"), hats keep going,
#                the hook alone washing into its dotted-eighth delay
#   lift      8  a second hook (a fast 4-note pluck arp) fades in, riser
#   drop2     8  the "anti-drop": bass on the root in the hook's rhythm,
#                no melody, the arp up high; low end back
#   pickup2   8  ride, arp, pad turnaround (next: :drop2); the performer
#                types `finish`
#   outro     8  the hook through its filter again, simple drums; next: :end
#                rings everything out
#
# Usage:
#     bin/songs/night_bus_flow.rb                 # plays live in the background session
#     bin/songs/night_bus_flow.rb last_stop.flac  # renders to a file instead (-f to overwrite)
#     bin/songs/night_bus_flow.rb --seed 2        # another chance branch after the pickup
#     bin/songs/night_bus_flow.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/night_bus_flow.rb'
#     last_stop                  # tracks and scenes only (go :drop etc. by hand), then
#     last_stop_form             # play the form and steer it yourself (seed: 2 for another branch)
#     last_stop(perform: true)   # or the whole performance
#
# Try (while it plays):
#     flow                       # => ▶ groove pass 1/1 (bar 3 of 8), next :build at 17:1 (open)
#     loop!; onward              # stay in a section, then move on (from the next boundary)
#     goto :breakdown            # what plays after this section
#     practice :drop             # go to the drop and stay there
#     skip                       # leave at the next bar line
#     seek :groove               # the groove from the next bar (the timeline keeps running)
#     finish                     # the outro next
#     at_marker(:drop2) { mute :pad }   # runs when the form next reaches drop2
#     scene :hush, others: :cut; go :hush   # cut everything (scenes ring out unless others: :cut)
#     take.form                  # the form as played, as a flow block to paste

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/fifth_pad'
require_relative '../synths/pluck'

module MB::Sound
  # The length of the performance in bars (to the end of the outro's ring
  # out, with the default seed).
  LAST_STOP_BARS = 92

  # One swing amount for every part that plays sixteenths (drums and bass
  # alike, so they groove together).
  LAST_STOP_SWING = 0.54

  # A drum Kit with every row (empty rows are rests), so scenes swap kits
  # without rebuilding the drums.  Hat, shaker, and ride rows swing.  With
  # +crash: true+, a crash on the first bar of every 8 from the launch
  # (the impact on drop downbeats).
  def self.last_stop_kit(crash: false, **rows)
    all = { kick: '', clap: '', hat: '', open_hat: '', shaker: '', ride: '', crash: '', low_tom: '' }.merge(rows)
    all[:crash] = 'X...............' if crash
    kit = grid(16, **all.transform_values { |p| p.empty? ? '.' * 16 : p })
    Sequence::Kit.new(kit.rows.to_h { |name, clip|
      clip = clip.swing(LAST_STOP_SWING) if [:hat, :shaker, :ride].include?(name)
      clip = clip.every(8) if name == :crash
      [name, clip]
    })
  end

  # The kits, with fills: a clap roll and toms in the last bar of every 8
  # (the :turn phrase fill; the plain clap and the open hat step aside),
  # and a crash on the first bar of every 8-bar block from the scene's
  # launch (impact on drop downbeats and pickups).
  def self.last_stop_kits
    turn = ->(kit) {
      kit
        .fill(:turn, clap: grid(16, '....X...x.x.xXXX', value: 39), low_tom: grid(16, '..........x..x.x', value: 45))
        .nofill(:clap, :open_hat, name: :turn)
    }
    core = { kick: 'X...x...X...x...', clap: '....X.......X...', hat: '..x...x...x...x.' }
    {
      intro: turn.(last_stop_kit(**core, shaker: '3735373537353735')).loop(align: :launch),
      groove: turn.(last_stop_kit(**core, shaker: '3735373537353735', open_hat: '..x.......x.....')).loop(align: :launch),
      build: turn.(last_stop_kit(kick: 'x...x...x...x...', hat: '..x...x...x...x.')).loop(align: :launch),
      drop: turn.(last_stop_kit(**core, hat: '..X...X...X...X.', shaker: '3735373537353735', crash: true)).loop(align: :launch),
      pickup: turn.(last_stop_kit(**core, hat: '..X...X...X...X.', shaker: '3735373537353735', ride: '6.4.6.4.6.4.6.4.', crash: true)).loop(align: :launch),
      cut: turn.(last_stop_kit(clap: '....X.......X...', hat: '..x...x...x...x.', shaker: '3735373537353735')).loop(align: :launch),
      outro: turn.(last_stop_kit(kick: 'X...x...X...x...', hat: '..x...x...x...x.')).loop(align: :launch),
    }
  end

  # The clips of the song, by name.  The hook is one bar from the i chord
  # (A C E, B passing) repeated over a silent i-iv-VII-VI (Am Dm G F):
  # each bar nudges the same rhythm and contour to that bar's chord tones,
  # so the melody moves the harmony while the bass stays on A.
  def self.last_stop_clips
    hook = seq(
      R, R, E5, R, C5, R, R, A4, R, R, B4, R, C5, R, A4, R,   # Am
      R, R, F5, R, D5, R, R, A4, R, R, C5, R, D5, R, A4, R,   # Dm
      R, R, D5, R, B4, R, R, G4, R, R, A4, R, B4, R, G4, R,   # G
      R, R, F5, R, C5, R, R, A4, R, R, B4, R, C5, R, A4, R,   # F (B natural passing)
    ).n16.loop(align: :launch)

    {
      hook: hook,
      hook_hi: hook.transpose(12),
      # Offbeat sub on the root
      sub: seq(R, A1, R, A1, R, A1, R, A1).n8.loop(align: :launch),
      # Rolling bass between the kicks (straight 16ths would fight the
      # swung hats, so it swings too)
      roll: seq(R, R, !A1, A1, R, R, A1, R, R, R, !A1, A1, R, C2, R, G1).n16.swing(LAST_STOP_SWING).loop(align: :launch),
      # The anti-drop: the hook's rhythm on the root, octave jumps
      root_hook: seq(
        R, R, !A1, R, A1, R, R, A2, R, R, A1, R, A1, R, A2, R,
      ).n16.loop(align: :launch),
      # One held note for tension (tied across the build)
      tension: seq(E5, Tie, Tie, Tie, Tie, Tie, Tie, Tie).n1.loop(align: :launch),
      # The second hook: a fast four-note arp up high
      arp: seq(A5, C6, E6, B5).n16.loop(align: :launch),
      # A static pad on A, turning to G on the 4th bar of each 4
      pad: seq(A2, A2, A2, G2).n1.legato(0.98).loop(align: :launch),
      # A placeholder clip for clipless patches (the riser)
      bar: seq(R).n1.loop,
    }
  end

  # The vocal-ish lead: a narrow pulse (asymmetric harmonics) through a
  # resonant 4-pole lowpass and two moving formant peaks in parallel, then a
  # sample-rate crush (sample-and-hold at a rate that rises with the note,
  # so low notes crush more), a little brightening, and a dotted-eighth
  # delay.  +cutoff+ may be a node (filter movement).
  def self.last_stop_hook(clip, cutoff: 2600, delay: 0.25, feedback: 0.35, level: 1.0)
    synth(clip, voices: 1) { |n|
      pitch = n.hz.glide(0.025, legato: true)
      src = pitch.pwm(0.16) * 0.6

      vowel = 0.31.hz.lfo.triangle * 0.5 + 0.5 # slowly between "oh" and "eh"
      body = src.lp4(cutoff, resonance: 0.5)
      f1 = src.filter(:bandpass, cutoff: vowel * 500 + 650, quality: 5)
      f2 = src.filter(:bandpass, cutoff: vowel * 900 + 1500, quality: 6)
      voice = body + f1 * 1.4 + f2 * 1.1

      rate = 2 ** ((n.number - 69) / 24.0) * 9000 # key-tracked, inverted crush
      crushed = voice.sample_hold(rate.tone.asquare)

      amp = n.env(0.004, 0.22, 0.45, 0.09, gm: false)
      (crushed * amp * 4).peq(3500.hz => [3.db, 0.8]).filter(:highpass, cutoff: 220, quality: 0.7)
    }.delay(1.n8.dotted, feedback: feedback, wet: delay).softclip(0.5, 0.95) * level
  end

  # The punchy saw bass: a short pitch bump (tom-like), a steep lowpass
  # opened only by a short filter envelope (a little top on the attack, not
  # acid), sustain 0 with a decay that suits sixteenths, and a sine under
  # it for weight.
  def self.last_stop_bass(clip, cutoff: 240, decay: 0.2)
    synth(clip, voices: 1) { |n|
      bump = n.env(0.0005, 0.03, 0, 0.02, curve: :linear, gm: false)
      freq = n.freq * (bump * 0.45 + 1)
      fenv = n.env(0.001, 0.06, 0, 0.04, gm: false)
      amp = n.env(0.001, decay, 0, 0.05, gm: false) * (n.velocity * 0.4 + 0.6)
      saw = freq.tone.ramp.lp4((2 ** (fenv * 2.5)) * cutoff, resonance: 0.35)
      ((saw + freq.tone * 0.6) * amp).softclip(0.7, 0.97)
    } * 1.0
  end

  # A sine sub with a gate envelope (offbeat sub in the groove).
  def self.last_stop_sub(clip)
    synth(clip, voices: 1) { |n|
      n.freq.tone * n.env(0.004, 0.09, 0.8, 0.05, gm: false)
    } * 0.25
  end

  # The held tension note: a soft triangle with a slow vibrato.
  def self.last_stop_tension(clip)
    synth(clip, voices: 1) { |n|
      (n.freq * (5.hz.lfo.sine * 0.004 + 1)).tone.triangle.filter(:lowpass, cutoff: 2500) *
        n.env(1.5, 0.1, 1.0, 1.2, gm: false)
    } * 0.09
  end

  # A pluck voice for the octave answer and the arp.
  def self.last_stop_pluck(clip, brightness: 9, level: 0.3)
    clip.synth(voices: 3) { |v| pluck_voice(v, sustain: 0.9, brightness: brightness) }
      .delay(1.n8.dotted, feedback: 0.3, wet: 0.2) * level
  end

  # A white-noise riser: a 4-bar highpass sweep and swell.
  def self.last_stop_riser
    noise.filter(:highpass, cutoff: tween([300, 9000], 4.bars, log: true, loop: false), quality: 2) *
      tween([0.02, 0.16], 4.bars, loop: false)
  end

  # Sets up the song on the current session: tempo, master, tracks, scenes
  # (each section of the form launches the scene of its name).  With
  # +perform: true+, also plays the form and schedules the performer's
  # commands.  Returns the clips.
  def self.last_stop(perform: false, seed: 1)
    c = last_stop_clips
    k = last_stop_kits
    bpm 126
    master { |mix| mix.softclip(0.5, 0.97) }
    quant 1

    track(:drums) { |kit|
      tr808(
        kit,
        kick: { tune: 50, decay: 0.5, tone: 0.4 }, clap: { decay: 0.25, tone: 0.6 },
        closed_hat: { decay: 0.04 }, open_hat: { decay: 0.25 }, cymbal: { decay: 0.9, tone: 0.65 },
        maracas: { level: 0.22 }, low_tom: { decay: 0.6 }, accent: 6
      ) * 0.85
    }
    track(:sub) { |clip| last_stop_sub(clip) }
    track(:bass) { |clip| last_stop_bass(clip) }
    track(:hook) { |clip| last_stop_hook(clip) }
    track(:hook_far) { |clip| last_stop_hook(clip, cutoff: 700, delay: 0.15) }
    track(:hook_rise) { |clip| last_stop_hook(clip, cutoff: tween([500, 3200], 8.bars, log: true, loop: false), delay: 0.2) }
    track(:hook_wash) { |clip| last_stop_hook(clip, cutoff: tween([900, 2600], 8.bars, log: true, loop: false), delay: 0.4, feedback: 0.55, level: 0.55) }
    track(:answer) { |clip| last_stop_pluck(clip, level: 1.3) }
    track(:arp) { |clip| last_stop_pluck(clip, brightness: 12, level: 0.9) }
    track(:tension) { |clip| last_stop_tension(clip) }
    track(:pad) { |clip| stereo(*fifth_pad(clip, voices: 2, cutoff: 900, release: 2)) * 0.25 }
    track(:riser, fade: 1/8r) { |_clip| last_stop_riser } # a tween, not notes: fades instead of ringing
    Session.current.arrangement.label(**c, **k.transform_keys { |n| :"kit_#{n}" })

    # Scenes: one focus per section (whole states; tracks left out ring out)
    scene :intro, drums: k[:intro]
    scene :groove, drums: k[:groove], sub: c[:sub], hook_far: c[:hook]
    scene :build, drums: k[:build], tension: c[:tension], hook_rise: c[:hook]
    scene(:gap) { meter 2, 4 }                                     # a half-bar breath
    scene(:drop, drums: k[:drop], bass: c[:roll], hook: c[:hook]) { meter 4, 4 }
    scene :pickup, drums: k[:pickup], bass: c[:roll], hook: c[:hook], answer: c[:hook_hi], pad: c[:pad]
    scene(:breakdown, drums: k[:cut], hook_wash: c[:hook], pad: c[:pad]) {
      master { |mix| mix.filter(:highpass, cutoff: 200, quality: 0.8).softclip(0.5, 0.97) } # the "cut"
    }
    scene :lift, drums: k[:cut], hook_wash: c[:hook], arp: c[:arp], pad: c[:pad]
    scene(:drop2, drums: k[:drop], bass: c[:root_hook], arp: c[:arp]) {
      master { |mix| mix.softclip(0.5, 0.97) } # low end back
    }
    scene :pickup2, drums: k[:pickup], bass: c[:root_hook], arp: c[:arp], pad: c[:pad]
    scene :outro, drums: k[:outro], hook_far: c[:hook]
    scene :riser, riser: c[:bar], others: :keep # a fill: adds the riser

    last_stop_performance(seed: seed) if perform
    c
  end

  # The song form (sections launch the scenes of their names).
  def self.last_stop_form(seed: 1)
    flow(seed: seed) do
      fill :turn, every: 8                         # clap/tom turnaround (drum kits' fill rows)
      intro     8
      groove    8
      build     8, fill: [:riser, 4]               # the riser scene for the last 4 bars
      gap       1                                  # one bar of 2/4 (the scene sets the meter)
      drop      8
      pickup    8, next: { breakdown: 3, drop: 1 } # usually the breakdown
      breakdown 8
      lift      8, fill: [:riser, 4]
      drop2     8
      pickup2   8, next: :drop2                    # keeps rolling until `finish`
      outro     8, next: :end                      # rings everything out
    end
  end

  # The performance: the form, plus what the performer types (each line is
  # printed as it runs, at the bar where it was typed).
  def self.last_stop_performance(seed: 1)
    say = ->(bar, line) { puts format("\e[2mbar %-5s\e[0m \e[36m›\e[0m %s", bar, line) }

    say[1, 'flow do ... end   # the form starts']
    last_stop_form(seed: seed)
    at_bar(12) { say[12, 'loop!   # the groove again']; loop! }
    at_bar(21) { say[21, 'onward']; onward }
    at_marker(:pickup) { say['pickup', "flow   # => #{Session.current.arrangement.playback}"] }
    at_marker(:pickup2) {
      session = Session.current
      bar = session.transport.bar_at(session.now).floor + 3
      at_bar(bar) { say[bar, 'finish   # the outro next']; finish }
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: LAST_STOP_BARS,
      seed: [1, 'Seed for the form\'s chance follow actions', '-s', Integer, 0..1_000_000],
    ) { |p| last_stop(perform: true, seed: p.seed) }
  end
end

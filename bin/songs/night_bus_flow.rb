#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Night Bus: Last Stop": the Night Bus set grown into a song form (phase 2
# of the arrangement tools; phase 1 is night_bus_set.rb).  A tech house
# track at 126 BPM in A minor, about 89 bars, built as one strong loop and
# arranged mostly by adding and removing parts in 8-bar blocks.  The form is
# written once as a `flow` block; the performer steers it live with loop!,
# onward, and finish, a weighted `pick` decides whether the first drop comes
# around once more, and a `goto` keeps the second drop rolling.  Knobs
# (phase 3) move the sound: :cut (the hook's lowpass), :space and :echo
# (its delay send and feedback), :air (a master highpass), and :morph (a crossfader between
# snapshots), turned by scenes, sections, and the performer.
#
#   intro     8  drums only: tight kick, late-feeling clap, offbeat hats,
#                a soft/accented shaker; a clap roll turnaround every 8
#                bars, toms every 4 in between
#   groove    8  the hook enters through a low lowpass (cut: 700), offbeat
#                sub on the root; the performer types `loop!` (it plays
#                twice), opens the filter a little on the repeat (`turn
#                :cut, 1300, over: 4`), then `onward`
#   build     8  thinned drums, one held E5 for tension, the hook opening out
#                of its filter (cut: [3200, from: 500, over: 8]); a noise
#                riser (a resonant highpass sweep and a slight swell) in the
#                last 4 bars (a fill)
#   gap       1  one 2/4 bar: everything rings out (scene drops ring by
#                default) for a half-bar breath; `meter 2, 4` in its scene
#   drop      8  dry: kick, punchy saw bass rolling against the kick, the
#                vocal-ish hook unfiltered, a crash on the downbeat
#   pickup    8  ride and an octave pluck answer the hook, a static pad
#                (leading the beat by half its attack); the performer snaps the
#                knobs (`snap :drop`) and throws the hook's delay on the
#                last 2 beats (`turn :space, 1` and `turn :echo, 0.6`,
#                back a beat into the next section); then a seeded
#                `pick`: usually on to the breakdown, one time in four the
#                drop and pickup once more
#   breakdown 8  low end out on the master (air: [200, over: 1.beat]), hats
#                keep going, the hook alone washing into its dotted-eighth
#                delay, its filter opening again from 900 Hz
#   lift      8  a second hook (a fast 4-note pluck arp) fades in, riser
#   drop2     8  the "anti-drop": bass on the root in the hook's rhythm,
#                no melody, the arp up high; low end back
#   pickup2   8  ride, arp, pad turnaround; `goto :rolling` (a label before
#                drop2) keeps it going until the performer types `finish`
#   outro     8  the hook through its filter again, simple drums, the knobs
#                morphing from the drop's snapshot back to the intro's
#                (`xfade :drop, :dark, :morph; turn :morph, 1, over: 8`);
#                the end of the form rings everything out
#
# Usage:
#     bin/songs/night_bus_flow.rb                 # plays live in the background session
#     bin/songs/night_bus_flow.rb last_stop.flac  # renders to a file instead (-f to overwrite)
#     bin/songs/night_bus_flow.rb --seed 12       # the other branch of the pick (one more drop)
#     bin/songs/night_bus_flow.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/night_bus_flow.rb'
#     last_stop                  # tracks and scenes only (go :drop etc. by hand), then
#     last_stop_form             # play the form and steer it yourself (seed: 12 for the other branch of the pick)
#     last_stop(perform: true)   # or the whole performance
#
# Try (while it plays):
#     flow                       # => ▶ groove pass 1/1 (bar 3 of 8), next :build at 17:1 (open)
#     loop!; onward              # stay in a section, then move on (from the next boundary)
#     goto :breakdown            # what plays after this section (or goto :rolling, a label)
#     practice :drop             # go to the drop and stay there
#     skip                       # leave at the next bar line
#     seek :groove               # the timeline back to the groove (bar 9), playing on from there
#     seek :rolling              # or to a label (drop2's bar, even before the form gets there)
#     finish                     # the outro next
#     at_marker(:drop2) { mute :pad }   # runs when the form next reaches drop2
#     markers                    # sections and labels (and your own markers) by bar
#     scene :hush, others: :cut; go :hush   # cut everything (scenes ring out unless others: :cut)
#     take.form                  # the form as played, as a flow block to paste
#     knobs                      # => {cut: "2600 Hz (200..6000 exp)", space: ..., ...}
#     turn :cut, 400, over: 2.bars, curve: :smooth, on: :bar   # sweep the hook down
#     turn :cut, tween([400, 4000, 900], 2.bars)   # follow a tween until turned again
#     move :air, 300; undo       # (move is turn) the low end out, then back at the next bar
#     snap :mine; recall :drop, over: 1   # remember, then morph back to the drop's knobs
#     turn :morph, 0, over: 4    # after the outro's xfade: back toward the drop
#     learn :cut                 # the next MIDI controller you move takes the hook filter
#     track(:drums, nudge: 6.ms) { ... }   # pull the kit late (see last_stop's drum_nudge:)

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

  # The kits (each named kit_<scene> for listings), with fills: a clap
  # roll in the last bar of every 8 (the :turn phrase fill; the plain clap
  # and the open hat step aside), toms in the last bar of every 4 (the
  # :toms fill; at bar 8 the longer :turn wins), and a crash on the first
  # bar of every 8-bar block from the scene's launch (impact on drop
  # downbeats and pickups).
  def self.last_stop_kits
    # (nofill before fill: marking the clap row :nofill after layering
    # the roll onto it made the roll play in every bar but the turn's;
    # since omnibus4 Clip#nofill keeps existing fill marks, so either order
    # works)
    turn = ->(kit) {
      kit
        .nofill(:clap, :open_hat, name: :turn)
        .fill(:turn, clap: grid(16, '....X...x.x.xXXX', value: 39))
        .fill(:toms, low_tom: grid(16, '..........x..x.x', value: 45))
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
    }.each { |name, kit| kit.named(:"kit_#{name}") }
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
    }.each { |name, clip| clip.named(name) }
  end

  # The vocal-ish lead: a narrow pulse (asymmetric harmonics) through a
  # resonant 4-pole lowpass and two moving formant peaks in parallel, then a
  # sample-rate crush (sample-and-hold at a rate that rises with the note,
  # so low notes crush more), a little brightening, and a dotted-eighth
  # delay send.  +cutoff+ may be a node (filter movement).
  #
  # The hook plays on the grid at +dry+; +send+ is the level of its
  # dotted-eighth echoes (relative to the dry hook) and +feedback+ how much
  # of each echo comes back; both may be nodes (the :space and :echo
  # knobs).  Until omnibus5 the hook was heard only through its delay (a
  # dotted eighth late: #delay's dry: defaults to 0) and the send scaled the
  # hook itself; maintainer, 2026-10-11: "Need dry on the grid" and, for
  # the throw, "Raising the send level or the feedback gain momentarily is
  # the way to go".
  def self.last_stop_hook(clip, cutoff: 2600, dry: 0.25, send: 0.35, feedback: 0.35, level: 0.8)
    hook = synth(clip, voices: 1) { |n|
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
    }

    (hook * dry).delay(1.n8.dotted, feedback: feedback, wet: send, dry: 1).softclip(0.5, 0.95) * level
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
    } * 1.4
  end

  # A sine sub with a gate envelope (offbeat sub in the groove).
  def self.last_stop_sub(clip)
    synth(clip, voices: 1) { |n|
      n.freq.tone * n.env(0.004, 0.09, 0.8, 0.05, gm: false)
    } * 0.32
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
      .delay(1.n8.dotted, feedback: 0.3, wet: 0.35, dry: 1) * (0.2 * level) # on the grid, echoes sent (omnibus5)
  end

  # A white-noise riser: a 4-bar resonant highpass sweep (the riser's
  # motion) with a slight swell, +6 dB over the 4 bars.  (Tweens in
  # Sessions used to sit at their last value; 2026-10-11 listening note:
  # "constant noise".)
  def self.last_stop_riser
    noise.filter(:highpass, cutoff: tween([250, 8000], 4.bars, log: true, loop: false), quality: 3) *
      tween([0.06, 0.12], 4.bars, loop: false)
  end

  # Sets up the song on the current session: tempo, master, tracks, scenes
  # (each section of the form launches the scene of its name).  With
  # +perform: true+, also plays the form and schedules the performer's
  # commands.  Returns the clips.
  #
  # +pad_lead+ is the pad track's lead: (0.5.attack by default, half its
  # 0.6 s attack: the maintainer's pick, 2026-10-11; :attack for all of it,
  # nil for none), +drum_nudge+ the drum track's nudge: (e.g. 6.ms to pull the
  # kit late against the bass; nil for none).
  def self.last_stop(perform: false, seed: 1, pad_lead: 0.5.attack, drum_nudge: nil)
    c = last_stop_clips
    k = last_stop_kits
    bpm 126
    quant 1

    # Knobs (phase 3): named values the scenes, sections, and performer turn
    knob :cut, 700, range: 200..6000, curve: :exp, unit: 'Hz' # the hook's lowpass
    knob :space, 0.35, range: 0..1                           # the hook's delay send
    knob :echo, 0.35, range: 0..0.85                         # the hook's delay feedback
    knob :air, 20, range: 20..400, curve: :exp, unit: 'Hz'   # a master highpass (the breakdown's "cut")
    knob :morph, 0                                           # a crossfader between snapshots

    master { |mix| mix.filter(:highpass, cutoff: knob(:air), quality: 0.8).softclip(0.5, 0.97) }

    track(:drums, nudge: drum_nudge) { |kit|
      tr808(
        kit,
        kick: { tune: 50, decay: 0.5, tone: 0.4 }, clap: { decay: 0.25, tone: 0.6 },
        closed_hat: { decay: 0.04 }, open_hat: { decay: 0.25 }, cymbal: { decay: 0.9, tone: 0.65 },
        maracas: { level: 0.22 }, low_tom: { decay: 0.6 }, accent: 6
      ) * 0.85
    }
    track(:sub) { |clip| last_stop_sub(clip) }
    track(:bass) { |clip| last_stop_bass(clip) }
    track(:hook) { |clip| last_stop_hook(clip, cutoff: knob(:cut), send: knob(:space), feedback: knob(:echo)) }
    track(:hook_far) { |clip| last_stop_hook(clip, cutoff: knob(:cut), dry: 0.15) }
    track(:hook_rise) { |clip| last_stop_hook(clip, cutoff: knob(:cut), dry: 0.2) }
    track(:hook_wash) { |clip| last_stop_hook(clip, cutoff: knob(:cut), dry: 0.4, send: 0.55, feedback: 0.55, level: 0.45) }
    track(:answer) { |clip| last_stop_pluck(clip, level: 1.3) }
    track(:arp) { |clip| last_stop_pluck(clip, brightness: 12, level: 0.68) }
    track(:tension) { |clip| last_stop_tension(clip) }
    # The pad leads the beat by half its 0.6 s attack (lead: 0.5.attack),
    # so each swell is half built at the bar line (maintainer, 2026-10-11)
    track(:pad, lead: pad_lead) { |clip| stereo(*fifth_pad(clip, voices: 2, cutoff: 900, release: 2)) * 0.25 }
    track(:riser, fade: 1/8r) { |_clip| last_stop_riser } # a tween, not notes: fades instead of ringing

    # Scenes: one focus per section (whole states; tracks left out ring out)
    scene :intro, drums: k[:intro]
    # Knob values in scenes turn as the scene launches: a number, or
    # [value, over:, curve:, from:] for a sweep
    scene :groove, drums: k[:groove], sub: c[:sub], hook_far: c[:hook], cut: 700
    scene :build, drums: k[:build], tension: c[:tension], hook_rise: c[:hook], cut: [3200, from: 500, over: 8, curve: :smooth]
    scene(:gap) { meter 2, 4 }                                     # a half-bar breath
    scene(:drop, drums: k[:drop], bass: c[:roll], hook: c[:hook], cut: 2600, space: 0.35, echo: 0.35, air: 20) { meter 4, 4 }
    scene :pickup, drums: k[:pickup], bass: c[:roll], hook: c[:hook], answer: c[:hook_hi], pad: c[:pad]
    scene :breakdown, drums: k[:cut], hook_wash: c[:hook], pad: c[:pad],
      cut: [2600, from: 900, over: 8, curve: :smooth], air: [200, over: 1.beat] # the "cut": low end out
    scene :lift, drums: k[:cut], hook_wash: c[:hook], arp: c[:arp], pad: c[:pad]
    scene :drop2, drums: k[:drop], bass: c[:root_hook], arp: c[:arp], air: 20 # low end back
    scene :pickup2, drums: k[:pickup], bass: c[:root_hook], arp: c[:arp], pad: c[:pad]
    scene :outro, drums: k[:outro], hook_far: c[:hook]
    scene :riser, riser: c[:bar], others: :keep # a fill: adds the riser

    last_stop_performance(seed: seed) if perform
    c
  end

  # The song form (sections launch the scenes of their names).
  def self.last_stop_form(seed: 1)
    flow(seed: seed) do
      fill :turn, every: 8                         # a clap roll turnaround (drum kits' fill rows)
      fill :toms, every: 4                         # toms halfway (bar 8 is the turn's)
      intro     8
      groove    8
      build     8, fill: [:riser, 4]               # the riser scene for the last 4 bars
      gap       1                                  # one bar of 2/4 (the scene sets the meter)
      drop      8
      pickup    8
      pick do |p|                                # usually straight on...
        p.option(3) { }
        p.option(1) { drop; pickup }             # ...sometimes the drop comes around again
      end
      breakdown 8
      lift      8, fill: [:riser, 4]
      label     :rolling
      drop2     8
      pickup2   8
      goto      :rolling                         # keeps rolling until `finish`
      outro     8                                # the end rings everything out
    end
  end

  # The performance: the form, plus what the performer types (each line is
  # printed as it runs, at the bar where it was typed).
  def self.last_stop_performance(seed: 1)
    say = ->(bar, line) { puts format("\e[2mbar %-5s\e[0m \e[36m›\e[0m %s", bar, line) }

    say[1, 'flow do ... end   # the form starts']
    last_stop_form(seed: seed)
    at_bar(2) { say[2, 'snap :dark   # the intro\'s knobs']; snap :dark }
    at_bar(12) { say[12, 'loop!   # the groove again']; loop! }
    at_bar(17) { say[17, 'turn :cut, 1300, over: 4, curve: :smooth   # open the far hook on the repeat']; turn :cut, 1300, over: 4, curve: :smooth }
    at_bar(21) { say[21, 'onward']; onward }
    at_marker(:pickup) {
      say['pickup', "flow   # => #{Session.current.arrangement.playback}"]
      say['pickup', 'snap :drop   # the drop\'s knobs']
      snap :drop
      session = Session.current
      bar = session.transport.bar_at(session.now).floor + 7
      at_bar(bar, beat: 3) {
        say["#{bar}.3", 'turn :space, 1, over: 1.n16; turn :echo, 0.6, over: 1.n16   # a delay throw']
        turn :space, 1, over: 1.n16
        turn :echo, 0.6, over: 1.n16
      }
      at_bar(bar + 1, beat: 2) {
        say["#{bar + 1}.2", 'turn :space, 0.35, over: 1.n8; turn :echo, 0.35, over: 1.beat   # and back']
        turn :space, 0.35, over: 1.n8
        turn :echo, 0.35, over: 1.beat
      }
    }
    at_marker(:outro) {
      say['outro', 'xfade :drop, :dark, :morph; turn :morph, 1, over: 8   # back to the dark']
      xfade :drop, :dark, :morph
      turn :morph, 1, over: 8
    }
    at_marker(:pickup2) {
      session = Session.current
      bar = session.transport.bar_at(session.now).floor + 3
      at_bar(bar) { say[bar, 'finish   # the outro next']; finish }
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: LAST_STOP_BARS,
      seed: [1, 'Seed for the form\'s chance (the pick after the pickup)', '-s', Integer, 0..1_000_000],
    ) { |p| last_stop(perform: true, seed: p.seed) }
  end
end

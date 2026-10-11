#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Night Bus": a live set sculpted in front of you, 48 bars at 124 BPM in A
# minor.  The arrangement isn't written as a timeline: it is performed,
# command by command, the way you would type it at the bin/sound.rb prompt
# (each line is printed as it lands), using the Set layer: tracks that
# remember their patches, scenes as whole states launched with `go`, soft
# mutes and solos, and undo of a mistake.  Phase 2 (song forms with
# `flow` with labels, goto, and pick, fills, ring-outs, a meter change) continues in
# night_bus_flow.rb.
#
#   1-4    intro      a fifths pad alone (go :intro)
#   5-12   build      a sparse 303 line and a four-on-the-floor kick join;
#                     at bar 9 a noise riser lifts in (a partial scene); at
#                     bar 11 the bass is swapped to the wrong key (oops),
#                     and `undo` puts it back on bar 12
#   13-24  drop       drums, the full acid line, a plucked hook; the pad is
#                     muted for air (bar 17), drums and bass soloed for a
#                     two-beat break (bar 19), then everything returns
#   25-32  breakdown  the pad's darker chords and the hook alone, a riser
#   33-40  drop 2     a permuted bass line and busier hats; the rhythm
#                     section (a mute group) drops out for the last beats
#   41-48  outro      pad and a thinning kick; the drums fade out over two
#                     bars, then everything fades
#
# Usage:
#     bin/songs/night_bus_set.rb                  # plays live in the background session
#     bin/songs/night_bus_set.rb night_bus.flac   # renders to a file instead (-f to overwrite)
#     bin/songs/night_bus_set.rb --bars 16        # just the first 16 bars
#     bin/songs/night_bus_set.rb --help           # all options
#
# Or in bin/sound.rb (then keep playing with it; `take.save` writes what
# you did as a replay script):
#     load 'bin/songs/night_bus_set.rb'
#     night_bus_set                  # the parts, tracks, and scenes, without the performance
#     go :intro; go :build           # launch scenes yourself (each on the next bar)
#     night_bus_set(perform: true)   # or the whole performance
#
# Try (after night_bus_set):
#     go :drop                       # => scene :drop lands 13:1 (queued): drums wait for a 4-bar line
#     mute :pad                      # now, with a 5 ms declick; muted tracks cost no CPU
#     solo :drums, :bass; solo       # a break, then everything back
#     mute :drums, on: :bar, fade: 2 # a synced two-bar fade out from the next bar
#     go :drop, on: 4                # on the next 4-bar line (plain numbers are bars)
#     go :drop, in: 2.bars           # two bars from now, then each track's own q: (drums: a 4-bar line)
#     go :drop, in: 2.bars, on: :beat  # two bars from now, then the next beat for every track
#     go :drop, at: bar(33)          # at bar 33 on the timeline
#     go :breakdown, fade: 1         # tracks that stop or start fade over a bar
#     swap :bass, bass_b.transpose(6); undo   # undo cancels it if it hasn't landed yet
#     bg :bass, bass_c               # a clip on a track plays through the track's patch
#     scenes; tracks; changes; take  # what's defined, what can be undone, what was played
#     take.save                      # a script that replays all of it bit for bit

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/acid'
require_relative '../synths/fifth_pad'
require_relative '../synths/pluck'

module MB::Sound
  # The set's length in bars.
  NIGHT_BUS_BARS = 48

  # The clips of the set, by name, each named with .named (`scenes` and
  # `tracks` list them by name; also bound as console variables by
  # .night_bus_set when given a binding).
  def self.night_bus_clips
    {
      chords_a: seq(A2, F2, C3, G2).n1.legato(0.95).loop,
      chords_b: seq(D3, A2, F2, E2).n1.legato(0.95).loop,
      bass_a: acid(A1, R, R, A1, R, R, A2, R, A1, R, R, ~C2, R, G1, R, E1).loop,
      bass_b: acid(!A1, A1, ~A2, A1, R, C2, !A1, T, ~D2, E2, A1.up, R, !G1, ~A1, A2, R).loop,
      hook: seq(E4, R, C5, B4, R, A4, G4.n4, R, E4, A4, R, C5.n4, B4, R).n8.loop,
      four: grid(16, kick: 'X...x...X...x...', hat: '..x...x...x...x.').loop,
      beat: grid(16, kick: 'X...x...X...x..x', clap: '....X.......X...', hat: 'x.xXx.x.x.xXx.xX').loop,
      beat2: grid(16, kick: 'X...x...X.x.x...', clap: '....X.......X..x', hat: 'xxXxxxXxxxXxxxXX', open_hat: '..x...x...x...x.').loop,
    }.tap { |c|
      c[:bass_c] = c[:bass_b].permute(seed: 4)
      c[:wrong] = c[:bass_b].transpose(6) # a tritone off: the mistake at bar 11
      c.each { |name, clip| clip.named(name) }
    }
  end

  # Sets up the set on the current session: tempo, master effects, tracks,
  # and scenes.  With +perform: true+, also schedules the performance (the
  # commands as they would be typed, each printed as it runs).  Returns the
  # clips.
  def self.night_bus_set(perform: false, cutoff: 1100)
    c = night_bus_clips
    bpm 124
    master { |mix| mix.softclip(0.5, 0.97) }
    quant 1

    # Tracks: patches build each part from the clip a scene gives it
    track(:pad) { |clip| stereo(*fifth_pad(clip, voices: 3, cutoff: cutoff, release: 3)) * 0.55 }
    track(:bass) { |clip| acid_voice(clip, cutoff: 260, reso: 0.72, decay: 0.9) * 0.6 }
    track(:drums, q: 4) { |kit| tr808(kit, kick: { tune: 48, decay: 0.9 }, accent: 6) * 0.9 }
    track(:lead) { |clip| clip.synth(voices: 3) { |v| pluck_voice(v, sustain: 2.5, brightness: 8) }.delay(3.n16, feedback: 0.35, wet: 0.3) * 0.5 }

    # Scenes: whole states (tracks not named stop), and partial ones
    scene :intro, pad: c[:chords_a]
    scene :build, pad: c[:chords_a], bass: c[:bass_a], drums: c[:four]
    scene :drop, pad: c[:chords_a], bass: c[:bass_b], drums: c[:beat], lead: c[:hook]
    scene :breakdown, pad: c[:chords_b], lead: c[:hook], fade: 1/2r
    scene :drop2, pad: c[:chords_a], bass: c[:bass_c], drums: c[:beat2], lead: c[:hook]
    scene :outro, pad: c[:chords_a], drums: c[:four], fade: 1/4r
    scene(:lift, others: :keep) { |_t|
      bg :riser, noise.at(0.12).filter(:highpass, cutoff: tween([300, 9000], 4.bars, log: true, loop: false), quality: 2), fade: 0
    }
    mutes :rhythm, :drums, :bass

    night_bus_performance(c) if perform
    c
  end

  # The performance: what a performer types, bar by bar.  Each command runs
  # in a scheduled block, so it lands exactly where it would have if typed
  # at that moment.
  def self.night_bus_performance(c)
    say = ->(bar, line) { puts format("\e[2mbar %-5s\e[0m \e[36m›\e[0m %s", bar, line) }

    at_bar(1) { say[1, 'go :intro'];                go :intro, on: :now }
    at_bar(5) { say[5, 'go :build'];                go :build }
    at_bar(9) { say[9, 'go :lift   # a riser on top'];  go :lift }
    at_bar(11) { say[11, 'swap :bass, wrong   # oops: a tritone off'];  swap :bass, c[:wrong], on: :now }
    at_bar(11, beat: 3) { say['11.3', 'undo   # back on the next bar'];  undo }
    at_bar(13) { say[13, 'go :drop'];               go :drop; stop :riser, fade: 0 }
    at_bar(17) { say[17, 'mute :pad   # air'];      mute :pad }
    at_bar(19, beat: 3) { say['19.3', 'solo :drums, :bass   # a two-beat break']; solo :drums, :bass }
    at_bar(20) { say[20, 'solo; unmute :pad'];      solo; unmute :pad, fade: 1/4r }
    at_bar(25) { say[25, 'go :breakdown'];          go :breakdown }
    at_bar(29) { say[29, 'go :lift'];               go :lift }
    at_bar(33) { say[33, 'go :drop2'];              go :drop2; stop :riser, fade: 0 }
    at_bar(39, beat: 3) { say['39.3', 'mute :rhythm   # drums and bass drop out'];  mute :rhythm }
    at_bar(41) { say[41, 'go :outro; unmute :rhythm']; go :outro; unmute :rhythm }
    at_bar(45) { say[45, 'mute :drums, on: :bar, fade: 2'];  mute :drums, fade: 2 }
    at_bar(47) { say[47, 'outro fade: 2'];          outro fade: 2 }
  end

  if main_script?(__FILE__)
    song_script(
      bars: NIGHT_BUS_BARS,
      cutoff: [1100, 'The pad\'s filter cutoff in Hz', '-c', Float, 200..8000],
    ) { |p| night_bus_set(perform: true, cutoff: p.cutoff) }
  end
end

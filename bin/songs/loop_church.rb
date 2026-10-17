#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Loop Church": a one-man-band live-looping set by Tiko Marvell.
#
# Tiko Marvell is a fictional funk / neo-soul live looper written for the
# persona panel experiment (2026-10-13: four musician personas reviewed the
# API and each wrote a 2-3 minute demo with it; research branch
# research-persona-looper, research/persona-panel/looper/, with Tiko's
# review, friction log, and a saved take).  The set moved here from that
# branch; its patches live in bin/synths/funk.rb (playable from
# MIDI, and saved as presets).
#
# Funk / neo-soul at 96 BPM in D dorian, 62 bars (about 2:35 plus the
# ring-out), built in front of you from nothing: every loop in it is
# played by a pair of scripted "hands" (stand-ins for a drum pad, a split
# keyboard, a talkbox keyboard, and a mic) through the session's MIDI
# inputs and recorded with the looper (`rec`), Capture MIDI (`capture`),
# and an overdub footswitch (a knob) on a delay-line audio loop.  The
# master bus is recorded with `rec_audio` from the first bar.
#
# Each performer command is console code run at its bar, and `--take
# FILE` (every song script's) records the run as a take: its replay
# script plays the whole night back bit for bit (the hands' MIDI is in
# the take).
#
#   bars 1-2   `arm :beat; rec :beat, 2`: mouth-drum kit (an 808 through
#              a formant "mouth"), kick on the ONE, snare laid back 18 ms
#   bars 3-4   `rec :bass, 2`: a ghost-noted funk bass, Dm9 | G13
#   bars 5-6   `rec :keys, 2`: FM electric piano stabs, rootless voicings
#   bars 7-8   `rec :perc, 2`: shaker, rim, and congas overdub
#   bars 9-16  `arm :lead`: the talkbox lead improvises (never looped);
#              bass drops out for bars 15-16, back on the ONE at 17
#   bar 17     `capture :hook, 2, input: :lead`: the lick from 15-16 loops
#   bars 19-20 `rec :stabs, 2`: a clav overdub played a tritone off (oops)
#   bar 22     `undo`: it looped once (bar 21), gone at bar 22 ("nah, keep it moving")
#   bars 25-26 the bridge: everything but the beat mutes; left hand and
#              right hand record bass_b and keys_b at once (Bbmaj9 | A7#9),
#              and the mic choir sings "ooh" into the audio loop
#              (`turn :dub, 1` ... `turn :dub, 0`)
#   bars 27-34 lead over the bridge loops
#   bar 35     A section back on the ONE, the choir loop still repeating
#   bars 43-50 everything (the peak), lead's last chorus
#   bars 51-58 strip it down: one layer muted every two bars
#   bars 59-62 the choir loop and shaker alone, then everything rings out
#
# As rendered by Tiko on the research branch (2026-10-13, measured; nobody
# had listened yet): 158.5 s, -12.7 LUFS integrated, -1.0 dBTP, LRA 5.6.
#
# Usage (from the repository root):
#     bin/songs/loop_church.rb                 # plays live
#     bin/songs/loop_church.rb -o x.flac -f    # renders
#     bin/songs/loop_church.rb -o x.flac --stems stems/ --take take.rb
#     ruby take.rb -o replay.flac                 # the saved take, replayed
#     ruby take.rb -o replay.flac -b 367,368      # at other buffer sizes
#     bin/songs/loop_church.rb -Q 0.7 -o x.flac   # loops quantized 70%

require 'bundler/setup'
require 'mb-sound'
require 'tmpdir'
require_relative '../synths/funk'

module MB::Sound
  LOOP_CHURCH_BPM = 96
  LOOP_CHURCH_BARS = 63

  # A MIDI Source playing a list of Events (times in seconds since it was
  # first read): one pair of the performer's scripted hands.
  class LoopChurchHands
    include MIDI::Source

    def initialize(events)
      @events = events.sort_by(&:time)
    end

    def read_events(from, to)
      @events.select { |e| e.time >= from && e.time < to }
    end
  end

  # ------------------------------------------------------------------
  # The patches (each track's sound; the clip is a recorded loop, or the
  # live input while the track is armed)
  # ------------------------------------------------------------------

  # The patches are in bin/synths/funk.rb.  tr808 can't take a
  # track's live input (a LiveClip) or the looper's empty placeholder clip,
  # so drum patches play a Stream of either (friction log F2/F3).
  def self.loop_church_drum_source(clip)
    clip.is_a?(Sequence::Clip) ? MIDI::Stream.for(clip) : clip.stream
  end

  # ------------------------------------------------------------------
  # The hands
  # ------------------------------------------------------------------

  # Returns a Hash from MIDI input name to Events.  Notes are
  # [bar (from 1), 16th step (0..15, may be fractional), note, length in
  # 16ths, velocity]; odd 16ths are swung by +swing+ (0.5 straight), and
  # each instrument has its own lateness and looseness in ms.
  def self.loop_church_hands(bpm: LOOP_CHURCH_BPM, swing: 0.57, seed: 96)
    bar = 240.0 / bpm
    step = bar / 16
    rnd = Random.new(seed)

    ev = ->(list, late_ms: 0, loose_ms: 0, channel: 0) {
      list.flat_map { |b, s, note, len, vel|
        st = s.to_f
        st += (swing - 0.5) * 2 if st.floor.odd? && st == st.floor
        on = (b - 1) * bar + st * step + late_ms / 1000.0 + rnd.rand(-1.0..1.0) * loose_ms / 1000.0
        on = 0.0 if on < 0
        off = on + len * step * 0.9
        n = note.respond_to?(:number) ? note.number.round : note
        [
          MIDI::Event.parse([0x90 | channel, n, vel.clamp(1, 127)], time: on.rationalize(1/48000r)),
          MIDI::Event.parse([0x80 | channel, n, 64], time: off.rationalize(1/48000r)),
        ]
      }
    }

    kick, snare, rim, hat, ohat, shaker, mconga, lconga = 36, 38, 37, 42, 46, 70, 63, 64

    # Beat (bars 1-2): kick dead on the grid, snare late, hats loose
    beat_k = [[1, 0, kick, 2, 118], [1, 7, kick, 1, 84], [1, 10, kick, 2, 104],
              [2, 0, kick, 2, 116], [2, 3, kick, 1, 72], [2, 10, kick, 2, 100], [2, 13, kick, 1, 78]]
    beat_s = [[1, 4, snare, 2, 116], [1, 12, snare, 2, 120], [2, 4, snare, 2, 114], [2, 12, snare, 2, 122]]
    beat_g = [[1, 7, snare, 1, 26], [1, 14, snare, 1, 30], [2, 9, snare, 1, 24], [2, 15, snare, 1, 38]]
    beat_h = (1..2).flat_map { |b| (0..15).map { |s| [b, s, hat, 1, s.even? ? (s % 4 == 0 ? 84 : 66) : 34] } }
    beat_h.reject! { |b, s, *| b == 2 && s == 14 }
    beat_h << [2, 14, ohat, 2, 80]

    # Perc overdub (bars 7-8)
    perc = (7..8).flat_map { |b|
      (0..15).map { |s| [b, s, shaker, 1, s.odd? ? 70 : 42] } +
        [[b, 3, rim, 1, 78], [b, 11, rim, 1, 72], [b, 6, lconga, 2, 90], [b, 7, mconga, 1, 60], [b, 14, lconga, 1, 84]]
    }

    # Bass (bars 3-4): Dm9 | G13, land the ONE, ghosts between
    bass = [
      [3, 0, D2, 3, 118], [3, 3, D2, 1, 30], [3, 6, A2, 1, 92], [3, 7, C3, 2, 98], [3, 10, D3, 1, 86],
      [3, 11, D2, 1, 28], [3, 12, F2, 2, 94], [3, 14, E2, 1, 74],
      [4, 0, G2, 3, 118], [4, 3, G2, 1, 30], [4, 6, D3, 1, 88], [4, 7, F3, 1, 80], [4, 8, G2, 2, 96],
      [4, 10, B2, 1, 82], [4, 11, G2, 1, 26], [4, 12, A2, 1, 90], [4, 14, C3, 1, 84], [4, 15, Cs3, 1, 88],
    ]

    # Keys (bars 5-6): rootless Dm9 (F A C E), G13 (F B E A); comping on
    # the anticipations
    dm9 = [F3, A3, C4, E4]
    g13 = [F3, B3, E4, A4]
    chord = ->(b, s, notes, len, vel) { notes.each_with_index.map { |n, i| [b, s + i * 0.08, n, len, vel - i * 4] } }
    keys = chord[5, 0, dm9, 3, 96] + chord[5, 6, dm9, 2, 78] + chord[5, 10, dm9, 5, 90] +
      chord[6, 0, g13, 3, 96] + chord[6, 6, g13, 2, 76] + chord[6, 10, g13, 4, 92] + chord[6, 14, g13.map { |n| n.transpose(-1) }, 2, 70]

    # The oops: clav stabs a tritone off (bars 19-20)
    stabs = [[19, 2], [19, 6], [19, 10], [19, 13], [20, 2], [20, 6], [20, 10], [20, 14]].flat_map { |b, s|
      chord[b, s, [Gs4, B4, Ds5], 1, 84]
    }

    # Bridge (bars 25-26): Bbmaj9 | A7#9, left and right hands together
    bass_b = [
      [25, 0, Bb1, 3, 118], [25, 3, Bb1, 1, 30], [25, 6, F2, 1, 90], [25, 7, A2, 2, 94], [25, 10, Bb2, 1, 84],
      [25, 12, D2, 2, 90], [25, 14, C2, 1, 76],
      [26, 0, A1, 3, 118], [26, 3, A1, 1, 30], [26, 6, E2, 1, 88], [26, 7, G2, 1, 84], [26, 8, A2, 2, 96],
      [26, 10, Cs3, 1, 82], [26, 12, C3, 1, 88], [26, 14, B1, 1, 80], [26, 15, Cs2, 1, 84],
    ]
    bbmaj9 = [A3, C4, D4, F4]
    a7s9 = [G3, Cs4, F4, C5]
    keys_b = chord[25, 0, bbmaj9, 3, 94] + chord[25, 6, bbmaj9, 2, 74] + chord[25, 10, bbmaj9, 6, 90] +
      chord[26, 0, a7s9, 3, 98] + chord[26, 6, a7s9, 2, 78] + chord[26, 10, a7s9, 6, 94]

    # The choir (bars 25-28 into the loop): A and D, then F and A
    choir = [[25, 0, A3, 30, 88], [25, 0, D4, 30, 82], [25, 0, F4, 14, 70], [26, 0, E4, 14, 70],
             [27, 0, A3, 30, 84], [27, 0, D4, 30, 80], [27, 0, F4, 14, 66], [28, 0, G4, 14, 66]]

    {
      pads: ev[beat_k, loose_ms: 2] + ev[beat_s, late_ms: 18, loose_ms: 3] + ev[beat_g, late_ms: 10, loose_ms: 4] +
        ev[beat_h, late_ms: -3, loose_ms: 7] + ev[perc, late_ms: 4, loose_ms: 8],
      left: ev[bass, late_ms: 4, loose_ms: 4] + ev[bass_b, late_ms: 4, loose_ms: 4],
      right: ev[keys, late_ms: 9, loose_ms: 4] + ev[stabs, late_ms: 6, loose_ms: 5] + ev[keys_b, late_ms: 9, loose_ms: 4],
      lead: ev[loop_church_solo(rnd), late_ms: 6, loose_ms: 9],
      voice: ev[choir, loose_ms: 10],
    }
  end

  # The talkbox lead's lines: bars 9-16 written out (the lick in 15-16 is
  # the one that gets captured), then bars 27-34 over the bridge chords
  # and 35-50 back on the vamp, improvised from a motif bank by a seeded
  # coin.
  def self.loop_church_solo(rnd)
    line = [
      # 9-10: warm-up, a call and an answer
      [9, 2, A4, 2, 90], [9, 4, C5, 2, 96], [9, 6, D5, 6, 104], [9, 14, C5, 1, 70],
      [10, 0, A4, 2, 92], [10, 3, G4, 1, 76], [10, 4, F4, 2, 88], [10, 6, D4, 6, 98],
      # 11-12: higher, with a bent-up approach (glide does the bend)
      [11, 2, F5, 1, 84], [11, 3, G5, 3, 108], [11, 8, F5, 1, 80], [11, 9, D5, 2, 94], [11, 12, C5, 2, 88],
      [12, 0, D5, 4, 104], [12, 6, A4, 1, 74], [12, 7, B4, 2, 86], [12, 10, A4, 1, 72], [12, 12, G4, 3, 90],
      # 13-14: repeated stabs, crowd call
      [13, 0, D5, 1, 112], [13, 2, D5, 1, 100], [13, 4, D5, 1, 108], [13, 7, F5, 2, 110], [13, 10, E5, 4, 100],
      [14, 0, C5, 1, 96], [14, 2, A4, 1, 88], [14, 4, C5, 2, 98], [14, 6, D5, 8, 106],
      # 15-16: THE lick (captured at 17)
      [15, 0, A4, 1, 104], [15, 2, C5, 1, 96], [15, 3, D5, 2, 110], [15, 6, F5, 1, 96], [15, 7, E5, 1, 88],
      [15, 8, D5, 2, 100], [15, 11, C5, 1, 84], [15, 12, A4, 3, 98],
      [16, 0, G4, 1, 100], [16, 2, A4, 1, 92], [16, 3, C5, 2, 104], [16, 6, D5, 1, 96], [16, 7, C5, 1, 84],
      [16, 8, A4, 2, 96], [16, 11, G4, 1, 80], [16, 12, F4, 2, 88], [16, 14, E4, 1, 76],
    ]

    # Motifs: [step, scale degree offset, length, velocity] in one bar
    motifs = [
      [[0, 0, 2, 100], [3, 2, 1, 84], [4, 4, 3, 104], [8, 3, 2, 90], [11, 2, 1, 76], [12, 0, 3, 96]],
      [[2, 4, 1, 92], [3, 5, 3, 106], [8, 4, 1, 84], [9, 2, 2, 94], [12, 0, 4, 98]],
      [[0, 7, 4, 110], [6, 6, 1, 84], [7, 4, 2, 96], [10, 2, 1, 80], [12, 4, 4, 100]],
      [[0, 0, 1, 104], [2, 0, 1, 96], [4, 0, 1, 104], [7, 2, 2, 108], [10, 1, 4, 96]],
      [[4, 4, 2, 96], [6, 2, 2, 90], [8, 0, 8, 102]],
      [[0, 2, 1, 92], [1, 3, 1, 88], [2, 4, 1, 96], [3, 6, 3, 110], [8, 7, 6, 104]],
    ]
    a_scale = scale(:dorian, :d)
    bridge = [scale(:lydian, :bb), scale(:minor, :d)]  # Bbmaj9: Bb lydian; A7#9: D minor's 5th
    root_deg = { a: [5, 4], b: [3, 5] } # degree (from 1) to start motifs on, per bar of the vamp

    phrase = ->(b, sc, start, rest_chance) {
      next [] if rnd.rand < rest_chance
      m = motifs[rnd.rand(motifs.length)]
      lift = rnd.rand < 0.3 ? 2 : 0
      m.map { |s, d, len, vel| [b, s, sc[start + d + lift - 1], len, vel - rnd.rand(0..10)] }
    }

    (27..34).each { |b| line.concat(phrase[b, bridge[(b - 27) % 2], root_deg[:b][(b - 27) % 2], b == 34 ? 0.6 : 0.15]) }
    (35..50).each { |b|
      sc = a_scale
      line.concat(phrase[b, sc, root_deg[:a][(b - 35) % 2], (b % 4 == 0) ? 0.5 : 0.12])
    }
    line
  end

  # ------------------------------------------------------------------
  # The set
  # ------------------------------------------------------------------

  # Defines the tracks, knobs, and master chain (the first console line
  # of the take).
  def self.loop_church_setup(quantize: 0)
    master_gain(0.db)
    # (gain inside the chain: master_gain comes after it, past the limiter)
    master { |mix| (mix * 2.5.db).compress(threshold: -16.db, ratio: 2.5, attack: 10.ms, release: 120.ms, makeup: 2.db).limit(ceiling: -1.db) }

    track(:beat, q: 1) { |c| funk_beat(loop_church_drum_source(c)) }
    track(:perc, q: 1) { |c| funk_perc(loop_church_drum_source(c)) }
    track(:bass, q: 1) { |c| funk_bass_voice(c) }
    track(:bass_b, q: 1) { |c| funk_bass_voice(c) }
    track(:keys, q: 1) { |c| funk_keys_voice(c) }
    track(:keys_b, q: 1) { |c| funk_keys_voice(c) }
    track(:stabs, q: 1) { |c| funk_clav_voice(c) }
    track(:lead, q: 1) { |c| funk_talkbox_voice(c) }
    track(:hook, q: 1) { |c| funk_talkbox_voice(c, level: 0.6).pan(-0.3) }
    # (knobs before the track that reads them: tracks build their patch
    # when defined; see Arrangement::PatchCheck)
    knob :dub, 0, smooth: 20.ms
    knob :keep, 0.82
    track(:choir, q: 1) { |c| funk_dub_loop(funk_choir_voice(c), dub: knob(:dub), keep: knob(:keep)) }
    nil
  end

  # The performance: console lines by bar, as Tiko would type them (with
  # the hype he'd shout, printed alongside).
  def self.loop_church_lines(quantize: 0)
    q = quantize.to_f > 0 ? ", quantize: [16, amount: #{quantize.to_f.rationalize(1/100r)}]" : ''
    {
      1 => [["rec_audio #{loop_church_audio.inspect}, overwrite: true", 'red light ON, we are LIVE'],
            ["arm :beat, input: :pads; rec :beat, 2#{q}", 'mouth drums, two bars, here we go']],
      3 => [["arm :bass, input: :left; rec :bass, 2#{q}", 'bass on the ONE']],
      5 => [["arm :keys, input: :right; rec :keys, 2#{q}", 'ninths and elevenths, church']],
      7 => [["arm :perc, input: :pads; rec :perc, 2#{q}", 'shaker overdub']],
      9 => [['arm :lead, input: :lead; arm :choir, input: :voice', 'talk to me']],
      # (disarm lands when the scheduler runs the line, half a bar early in
      # a script, so the monitors are disarmed later; friction log F7)
      11 => [['disarm :beat, :bass, :keys, :perc']],
      15 => [['mute :bass, on: :bar', 'bass OUT...']],
      17 => [['unmute :bass, on: :bar; capture :hook, 2, input: :lead', '...and back on the ONE; keep that lick']],
      19 => [["arm :stabs, input: :right; rec :stabs, 2#{q}", 'clav overdub']],
      22 => [['undo; disarm :stabs', 'nah. NAH. keep it moving']],
      25 => [['mute :bass, :keys, :perc, :hook, :stabs, on: :bar; arm :bass_b, input: :left; arm :keys_b, input: :right; rec :bass_b, :keys_b, 2', 'bridge: both hands'],
             ['turn :dub, 1, on: :bar', 'mic into the loop']],
      29 => [['turn :dub, 0, on: :bar; disarm :bass_b, :keys_b', 'footswitch up, it keeps going']],
      35 => [['mute :bass_b, :keys_b, on: :bar; unmute :bass, :keys, :hook, on: :bar', 'back HOME']],
      43 => [['unmute :perc, on: :bar', 'everybody now']],
      51 => [['mute :hook, on: :bar', 'take it down...']],
      53 => [['mute :keys, on: :bar']],
      55 => [['mute :bass, on: :bar']],
      57 => [['mute :beat, on: :bar; disarm :lead', 'just the church']],
      59 => [['turn :keep, 0.55, on: :bar']],
      61 => [['mute :perc, on: :bar, fade: 1; mute :"choir/live", on: :bar, fade: 2', 'goodnight...']],
      63 => [['stop_rec_audio on: :bar']],
    }
  end

  # Where rec_audio writes the master bus (scratch: the render is the
  # deliverable; this proves the command works mid-set):
  # $LOOP_CHURCH_AUDIO, or a file in the system's temporary directory.
  def self.loop_church_audio
    ENV.fetch('LOOP_CHURCH_AUDIO') { File.join(Dir.tmpdir, 'loop_church_rec_audio.flac') }
  end

  # Sets up the set on the current session, attaches the hands, and
  # schedules the performance: console code run at its bars (a song
  # script's --take records the whole run as a take).
  def self.loop_church(quantize: 0, swing: 0.57)
    session = Session.current
    transport.bpm = LOOP_CHURCH_BPM
    b = Take.console_binding
    Session.with_context(session: session) { b.eval("loop_church_setup(quantize: #{quantize.inspect})") }

    hands = loop_church_hands(swing: swing)
    hands.each { |name, events| session.midi_in(name).input = MIDI::Stream.new(LoopChurchHands.new(events)) }

    say = ->(bar, code, hype) { puts format("\e[2mbar %-3s\e[0m \e[36m›\e[0m %s%s", bar, code, hype ? "   \e[33m# #{hype}\e[0m" : '') }
    loop_church_lines(quantize: quantize).each do |bar, lines|
      perform = -> {
        lines.each { |code, hype|
          say[bar, code, hype]
          Session.with_context(session: session) { b.eval(code, "loop_church bar #{bar}") }
        }
      }
      # Bar 1's lines run right away (typed before the count-in), so the
      # session isn't idle at the start (bin/scene_profile.rb -R stops at
      # once when a song's first sound comes from a scheduled block)
      bar == 1 ? perform.call : at_bar(bar, &perform)
    end
    nil
  end

  if main_script?(__FILE__)
    song_script(
      bars: LOOP_CHURCH_BARS,
      quantize: [0.0, 'Quantize amount for the recorded loops (0: as played, keeping the swing)', '-Q', Float, 0.0..1.0],
      swing: [0.57, "The hands' swing (0.5 straight)", '-S', Float, 0.5..0.75],
    ) { |p|
      loop_church(quantize: p.quantize, swing: p.swing)
    }
  end
end

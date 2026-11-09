module MB
  module Sound
    # Cinematic booms (boom-1, 2026-11-09; the maintainer: "a cinematic
    # boom instrument in the library"; design/notes/library.md, Booms):
    # trailer and sound-design libraries' "booms" or "impacts", a hit whose
    # body falls from a punchy tone into a long sub, with a click on the
    # strike and a room around it; and the "sub drop", the falling sub
    # without the hit.  Built from library pieces only: a pitch-swept sine
    # (and triangle) under an envelope, a lowpassed impulse (the click),
    # filtered noise (a burst and a rumble), a sine sub, a soft clipper,
    # and a Reverb.
    #
    # Each note strikes one boom landing on the note's pitch (the body
    # starts +drop+ octaves above it and falls over +sweep+); note lengths
    # don't matter (a one-shot, as drums are).  Velocity is the level, and
    # with +vel_depth+ and +vel_bright+ also the depth of the drop and the
    # click, noise burst, and drive.  Presets are settings of one voice, so every
    # setting is a Param (knobs on a track: `track :fx, L.inst.boom`).
    #
    #     play boom(seq(G1, R, R, R).n1)              # the default boom, every 4 bars
    #     play boom(G1)                               # one hit (also boom(:trailer, E1))
    #     L.inst.boom.trailer.ping                    # one hit at the preset's note
    #     kit { voice(:boom) { |h| h.boom(:impact) } } # a kit piece
    module Boom
      extend Presettable

      # The settings a voice reads (all Params, below).
      VOICE_KEYS = %i[
        note drop sweep sweep_curve shape punch punch_time decay curve sub sub_decay click click_tone
        noise noise_tone noise_decay rumble rumble_tone rumble_decay drive vel_depth vel_bright
      ].freeze

      preset_family :boom, kind: :instrument, label: 'boom preset', keys: VOICE_KEYS + %i[tail tail_length room damping width level voices],
        about: 'Cinematic booms and impacts: boom(clip, :trailer), L.inst.boom.trailer.(clip), L.inst.boom.trailer.ping',
        apply: ->(name, source = nil, **o) { MB::Sound.boom(source, name, **o) },
        code: ->(e) { "boom(midi, #{e.name.inspect})" }

      param :note, 31, range: 12..72, description: 'The note a one-shot or kit hit lands on (MIDI number; 31 is G1)'
      param :drop, 2.58, range: 0.0..5.0, description: 'Octaves the body falls onto the note'
      param :sweep, 0.203, range: 0.005..8.0, curve: :exp, unit: 's', description: 'Seconds the pitch fall takes (to -60 dB of the drop along sweep_curve)'
      param :sweep_curve, 38.3, range: 0.0..90.0, description: 'Shape of the pitch fall in dB (0 falls evenly in octaves, 60 dives fast and settles)'
      param :shape, 0.0, range: 0.0..1.0, description: 'Body wave: 0 sine, 1 triangle'
      param :punch, 0.48, range: 0.0..1.0, description: 'How far the level falls from the strike to the body (0 none)'
      param :punch_time, 0.0168, range: 0.005..1.0, curve: :exp, unit: 's', description: 'Seconds the strike takes to fall to the body'
      param :decay, 2.34, range: 0.05..20.0, curve: :exp, unit: 's', description: 'Seconds the body takes to fall silent after the strike'
      param :curve, 4.5, range: 0.0..90.0, description: 'Shape of the body decay in dB (0 linear, 60 exponential)'
      param :sub, 0.0, range: 0.0..1.0, description: 'Level of a sine sub on the note (held while the body falls)'
      param :sub_decay, 3.0, range: 0.05..20.0, curve: :exp, unit: 's', description: 'Seconds the sub takes to fall silent'
      param :click, 3.17, range: 0.0..4.0, description: 'Height of the click on the strike (a lowpassed impulse after the drive; 1 peaks about as high as a full-velocity body)'
      param :click_tone, 800.0, range: 200.0..16000.0, curve: :exp, unit: 'Hz', description: 'Lowpass cutoff of the click in Hz (lower: a softer, wider thump)'
      param :noise, 0.061, range: 0.0..1.0, description: 'Level of a noise burst on the strike (air, hiss, debris)'
      param :noise_tone, 18000.0, range: 100.0..18000.0, curve: :exp, unit: 'Hz', description: 'Lowpass cutoff of the noise burst in Hz'
      param :noise_decay, 2.0, range: 0.002..10.0, curve: :exp, unit: 's', description: 'Seconds the noise burst takes to fall 60 dB'
      param :rumble, 0.715, range: 0.0..1.0, description: 'Level of a low noise tail under the boom'
      param :rumble_tone, 480.0, range: 40.0..4000.0, curve: :exp, unit: 'Hz', description: 'Lowpass cutoff of the rumble in Hz'
      param :rumble_decay, 5.6, range: 0.05..20.0, curve: :exp, unit: 's', description: 'Seconds the rumble takes to fall silent (along the body\'s curve)'
      param :drive, 0.249, range: 0.0..1.0, description: 'Soft clipping of the body and noise burst (0 clean, 1 up to +18 dB into the clipper)'
      param :vel_depth, 0.5, range: 0.0..1.0, description: 'How much velocity scales the drop (0 none, 1 all)'
      param :vel_bright, 0.5, range: 0.0..1.0, description: 'How much velocity scales the click, noise burst, and drive (0 none, 1 all)'
      param :tail, 0.308, range: 0.0..2.0, description: 'Reverb tail level (wet gain; the dry boom stays at 1; 0 for none)'
      param :tail_length, 8.1, range: 0.2..30.0, curve: :exp, unit: 's', description: 'Reverb decay time (RT60) in seconds (read when built)'
      param :room, 0.675, range: 0.0..1.0, description: 'Reverb room size (read when built)'
      param :damping, 0.62, range: 0.0..1.0, description: 'Reverb high-frequency damping (0 bright, 1 dark; read when built)'
      param :width, 0.2, range: 0.0..1.0, description: 'Stereo width of the tail (0 mono, 1 the reverb as it is)'
      param :level, 1.03, range: 0.0..4.0, description: 'Output gain (presets: one hit at the default velocity at about -20.3 LUFS through the default master, or its peak at -3 dBFS there)'
      param :voices, 4, range: 1..16, description: 'Booms that ring at once'

      # Body attack in seconds (the strike's rise).
      ATTACK = 0.001

      # Sub attack in seconds (softer than the strike, so the sub adds no
      # click of its own).
      SUB_ATTACK = 0.005

      # The reverb tail's layout seed (fixed, so a preset's room is always
      # the same room, as Reverb's presets are).
      TAIL_SEED = 1

      # The click's impulse is the setting × rate / (CLICK_PEAK × tone),
      # so its lowpassed peak is about the setting (measured: the 2-pole
      # lowpass's impulse response peaks at 2.83 fc / rate for tones up to
      # 2 kHz, 2.43 at 8 kHz).
      CLICK_PEAK = 2.83

      # Clip threshold and limit of the drive stage (GraphNode#softclip):
      # linear up to 0.8, so an undriven hit passes almost untouched.
      CLIP = [0.8, 1.2].freeze

      # Settings a track turns into knobs (Arrangement::TrackKnobs): the
      # ones the voice reads as signals, and the tail level.  The note, the
      # reverb's room, length, and damping, and voices are build-time, and
      # level is the track's fader.
      KNOB_PARAMS = %i[
        drop sweep sweep_curve shape punch punch_time decay curve sub sub_decay click click_tone
        noise noise_tone noise_decay rumble rumble_tone rumble_decay drive vel_depth vel_bright tail width
      ].freeze

      # The default boom (the params' defaults): fitted to a soft synth's
      # "big kick" boom (boom-1; see design/notes/library.md, Booms).
      preset :cinematic, about: 'A cinematic boom: a punchy strike falling two octaves onto a long sub, a click, a dark room',
        tags: %i[deep sub hit]

      preset :sub_drop, about: 'A sub drop: a sine falling slowly onto the note, no strike or click',
        tags: %i[sub drop slow],
        note: 28, drop: 2.0, sweep: 1.6, sweep_curve: 6.0, punch: 0.0, decay: 3.5, curve: 6.0, click: 0.0, noise: 0.0, rumble: 0.0,
        drive: 0.15, vel_depth: 0.0, vel_bright: 0.0, tail: 0.2, tail_length: 3.0, room: 0.7, damping: 0.6, width: 0.5, level: 0.642

      preset :impact, about: 'A short, tight impact: a fast dive, a hard click, a small bright room',
        tags: %i[short tight hit],
        note: 33, drop: 2.5, sweep: 0.07, sweep_curve: 40.0, punch: 0.6, punch_time: 0.03, decay: 0.7, curve: 30.0,
        click: 0.8, click_tone: 4000.0, noise: 0.15, noise_tone: 5000.0, noise_decay: 0.25, rumble: 0.1, rumble_tone: 1500.0, rumble_decay: 0.4,
        drive: 0.4, tail: 0.25, tail_length: 1.5, room: 0.5, damping: 0.5, width: 0.6, level: 1.461

      preset :trailer, about: 'A long trailer boom: a deep strike over a held sub, a rumble, a huge wide room',
        tags: %i[huge long wide],
        note: 28, drop: 2.0, sweep: 0.4, sweep_curve: 30.0, shape: 0.2, punch: 0.35, punch_time: 0.1, decay: 6.0, curve: 6.0,
        sub: 0.5, sub_decay: 7.0, click: 0.6, click_tone: 1500.0, noise: 0.15, noise_tone: 3000.0, noise_decay: 1.5,
        rumble: 0.5, rumble_tone: 600.0, rumble_decay: 5.0, drive: 0.35, tail: 0.6, tail_length: 8.0, room: 0.9, damping: 0.5, width: 0.9,
        level: 0.515

      module_function

      # The settings of boom preset +name+ with the declared defaults for
      # what it leaves out, then +overrides+ (nil values ignored).
      def settings(name, **overrides)
        declared = preset_params.transform_values(&:default)
        declared.merge(preset_settings(name)).merge(overrides.compact)
      end

      # The boom instrument (see BoomMethods#boom): a Synth striking
      # #voice for every note of +source+, through the reverb tail.  +seed+
      # seeds the Synth's lanes (the click and noise; drawn when nil, as
      # graph documents record).
      def build(source, name, seed: nil, **overrides)
        s = settings(name, **overrides)
        out = MB::Sound.synth(source, voices: Integer(s[:voices]), seed: seed) { |v| voice(v.trigger, v.freq, s) }
        out = tail(out, s)
        level = s[:level]
        level.is_a?(Numeric) && level == 1 ? out : out * level
      end

      # One boom voice (mono, no tail) struck by +trigger+ (an impulse at
      # each hit, valued at its velocity: a Synth voice's v.trigger or a kit
      # Hit's h.t) landing on +freq+ (Hz, a Pitch, or a node such as
      # v.freq), with settings +s+ (a Hash of VOICE_KEYS; numbers or nodes).
      def voice(trigger, freq, s)
        s = preset_params.transform_values(&:default).merge(s)
        vel = (amount?(s[:vel_depth]) || amount?(s[:vel_bright])) ? trigger.sample_hold(trigger) : nil
        depth = scaled(s[:drop], vel, s[:vel_depth])
        bright = vel && amount?(s[:vel_bright]) ? (1 - s[:vel_bright]) + vel * s[:vel_bright] : 1

        f = Drums.hz(freq)
        f = f.constant if f.is_a?(Numeric)
        body_freq = f
        if amount?(depth)
          dive = Drums.decay_env(trigger, s[:sweep], attack: 0, curve: s[:sweep_curve], velocity: false)
          body_freq = f * 2**(dive * depth)
        end

        wave = body_freq.tone.sine.reset(trigger)
        if amount?(s[:shape])
          tri = body_freq.tone.triangle.reset(trigger)
          wave = wave * (1 - s[:shape]) + tri * s[:shape]
        end
        body = wave * amp_env(trigger, s)

        hit = body
        white = amount?(s[:noise]) || amount?(s[:rumble]) ? MB::Sound.noise : nil
        if amount?(s[:noise])
          n = white.filter(:lowpass, cutoff: s[:noise_tone], quality: 0.7)
          hit += n * Drums.decay_env(trigger, s[:noise_decay], curve: 60) * times(s[:noise], bright)
        end

        # (always on, so a drive knob at 0 plays what a number 0 plays)
        gain = amount?(s[:drive]) ? 2**(times(s[:drive], bright) * 3) : 1
        hit = (gain == 1 ? hit : hit * gain).softclip(*CLIP)

        # The click after the clipper, so its peak stays a peak
        click = nil
        if amount?(s[:click])
          # (scaled so the lowpassed impulse peaks near the setting)
          height = times(s[:click], bright) * (trigger.sample_rate / CLICK_PEAK) / s[:click_tone]
          click = (trigger * height).filter(:lowpass, cutoff: s[:click_tone], quality: 0.7)
        end

        sub = amount?(s[:sub]) ? f.tone.sine.reset(trigger) * Drums.decay_env(trigger, s[:sub_decay], attack: SUB_ATTACK, curve: s[:curve]) * s[:sub] : nil
        rumble = nil
        if amount?(s[:rumble])
          n = white.filter(:lowpass, cutoff: s[:rumble_tone], quality: 0.7)
          rumble = n * Drums.decay_env(trigger, s[:rumble_decay], attack: SUB_ATTACK, curve: s[:curve]) * s[:rumble]
        end
        Drums.mix(hit, click || 0, sub || 0, rumble || 0)
      end

      # The body's amplitude envelope: up to the velocity over ATTACK, down
      # by +punch+ over +punch_time+, then to silence over +decay+ along
      # +curve+ (a fourth segment is the release, so a hit without a gate
      # plays all three and stays at 0).
      def amp_env(trigger, s)
        body = 1 - s[:punch]
        MB::Sound.adsr(
          [[1, ATTACK, 0], [body, s[:punch_time], 30], [0, s[:decay], s[:curve]], [0, ATTACK]],
          trigger: trigger, velocity: trigger, sensitivity: 0..1, hold: false
        )
      end

      # +out+ through the reverb tail of settings +s+ (stereo), or +out+
      # when the tail is a number 0.
      def tail(out, s)
        return out unless amount?(s[:tail])
        out = out.reverb(room_size: s[:room], decay: s[:tail_length], damping: s[:damping], wet: s[:tail], dry: 1, output_channels: 2, seed: TAIL_SEED)
        s[:width].is_a?(Numeric) && s[:width] == 1 ? out : out.width(s[:width])
      end

      # The note a one-shot of preset +name+ lands on.
      def home_note(name)
        Note.new(Integer(settings(name)[:note]))
      end

      # A one-note clip striking boom preset +name+ once at +pitch+ (a Note
      # or MIDI number; the preset's note by default).
      def strike_clip(name, pitch = nil)
        note = pitch.nil? ? home_note(name) : (pitch.is_a?(Numeric) ? Note.new(pitch) : pitch)
        MB::Sound.seq(note).n4
      end

      # A graph striking boom entry +entry+ once (see Library::Entry#ping)
      # at +pitches+ (none: the preset's note; several: a chord), or
      # playing a clip or other note source given instead, as written.
      def ping(entry, pitches)
        source = pitches.length == 1 && Struck.note_source?(pitches[0]) ? pitches[0] : nil
        if source.nil? && pitches.any? { |p| Struck.note_source?(p) }
          raise ArgumentError, "ping takes pitches (#{entry.head_path}.ping(E1)) or one clip (#{entry.head_path}.ping(seq(G1, R, R, R).n1)); got a note source among #{pitches.length} arguments"
        end
        source ||= pitches.length > 1 ? MB::Sound.seq(pitches.map { |p| p.is_a?(Numeric) ? Note.new(p) : p }).n4 : strike_clip(entry.name, pitches[0])
        MB::Sound.boom(source, entry.name)
      end

      # +a+ × +b+, skipping a factor that is a number 1.
      def times(a, b)
        return a if b.is_a?(Numeric) && b == 1
        return b if a.is_a?(Numeric) && a == 1
        a * b
      end

      # True unless +x+ is a number 0 (nodes count: a knob may move).
      def amount?(x)
        !(x.is_a?(Numeric) && x == 0)
      end

      # +value+ scaled by velocity +vel+ by +amount+ (0..1): value × (1 -
      # amount + amount × vel); +value+ itself without a velocity or with a
      # number amount of 0.
      def scaled(value, vel, amount)
        return value if vel.nil? || !amount?(amount) || !amount?(value)
        value * ((1 - amount) + vel * amount)
      end
    end
  end
end

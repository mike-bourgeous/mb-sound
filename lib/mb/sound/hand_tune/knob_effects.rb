module MB
  module Sound
    module HandTune
      # How far below the note itself a knob's change must stay for the
      # tuner to mark the knob as doing nothing (dB).
      DEAD_DB = -60.0

      # How far the probe moves a knob: this share of its travel, toward
      # its farther end, in its own scale (curve).
      PROBE_SHARE = 0.4

      module_function

      # What each knob of graph document +path+ does to one note right now
      # (tuner-fixes-2; Linux's research-tune-recovery on the 2026-11-07
      # tunings: the vocal fit's env_decay, the one knob he turned, did
      # nothing under a sustain of 1.0, and kick2's hat_tune and hat_decay
      # nothing under a hat_level of 0): { param => dB } of the change's
      # RMS against the note's RMS when the knob moves PROBE_SHARE of its
      # travel toward its farther end in its own scale (one render a knob:
      # about 0.3 s each for the init voice's 0.4 s note in the Mac
      # container, mostly building the document), -Infinity when the
      # samples don't change.  One note: a glide or anything else that
      # needs two notes reads as no effect.  +values+ are the knobs now
      # ({ param => value }); the note is +note+ at +velocity+ held +hold+
      # seconds, rendered for
      # +seconds+ (HandTune.render, so the same seeds).  +params+ limits it
      # to those (default: every bounded numeric param).  Offline: the
      # tuner runs it in its worker process (Wizard#knob_effects).
      def knob_effects(path, values, note: 60, velocity: 0.8, hold: nil, seconds: 1.0, params: nil)
        doc = GraphIO.parse(path)
        decls = doc.declarations.select { |_, p| p.is_a?(Param) && p.numeric? && p.bounded? }
        decls = decls.slice(*params.map(&:to_sym)) if params
        values = values.transform_keys(&:to_sym)
        render = ->(v) { Numo::DFloat.cast(HandTune.render(path, v, note: note, velocity: velocity, hold: hold, seconds: seconds)[0]) }
        base = render.(values)
        level = Math.sqrt((base**2).mean)
        decls.to_h { |name, p|
          lo = Param.magnitude(p.range.begin).to_f
          hi = Param.magnitude(p.range.end).to_f
          curve = Arrangement::TrackKnobs.curve_of(p) == :exp ? :exp : :linear
          now = (values[name] || Param.magnitude(p.default)).to_f
          pos = Param::Scale.position(now, lo, hi, curve).clamp(0.0, 1.0)
          v = Param::Scale.value(pos < 0.5 ? pos + PROBE_SHARE : pos - PROBE_SHARE, lo, hi, curve)
          v = v.round if p.stepped?
          diff = render.(values.merge(name => v)) - base
          d = Math.sqrt((diff**2).mean)
          [name, d == 0 ? -Float::INFINITY : 20 * Math.log10(d / [level, 1e-12].max)]
        }
      end

      # The knobs of +effects+ (.knob_effects) that change the note by
      # less than +below+ dB: dead at these settings.
      def dead_knobs(effects, below: DEAD_DB)
        effects.select { |_, db| db < below }.keys
      end
    end
  end
end

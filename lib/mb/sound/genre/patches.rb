module MB
  module Sound
    module Genre
      # Small patches that genre templates' roles use where no preset fits
      # (role patches name a preset first, then these, then MB::Sound
      # methods).  Each takes the role's MIDI source first.
      module Patches
        module_function

        # A noise riser that ignores its notes: a resonant bandpass sweeping
        # up from +from+ to +to+ Hz over +bars+ bars from the track's launch,
        # swelling to +level+ (from "Tunnel Vision"'s riser).  Give its role
        # a short fade: so a scene change takes it away cleanly.
        def riser(_source, bars: 4, from: 250, to: 10000, level: 0.25)
          sweep = MB::Sound.tween([from, to], bars.bars, log: true, loop: false)
          MB::Sound.noise.filter(:bandpass, cutoff: sweep, quality: 3) * MB::Sound.tween([level * 0.12, level], bars.bars, loop: false)
        end
      end
    end
  end
end

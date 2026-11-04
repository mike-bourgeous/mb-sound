module MB
  module Sound
    module Drums
      # Kit designs fitted to recordings (Drums::Machine voices whose
      # numbers came from a fit; the recordings were measured only and
      # never ship: only the numbers do).  Each is a library kit entry
      # (`L.kit.fit909_kick`) and a design kit blocks borrow
      # (`kit(src) { borrow :fit909_kick }`; Builder#borrow).
      #
      #     play L.kit.fit909_kick                                       # a beat (the kick's row)
      #     bg :kick, L.kit.fit909_kick.(grid(16, kick: 'X...X...X...X...').loop, kick: { decay: 0.6 })
      #     bg :beat, kit(grid(16, kick: 'X...X...X...X...', clap: '....X.......X...').loop) { borrow :fit909_kick; tr909 except: :kick }
      module Fits
        module_function

        # A TR-909 kick fitted to "TR-909 House Beat.wav" by Thejames428
        # (Wikimedia Commons, CC BY-SA 4.0; measured only, not
        # distributed): the tr909 kick's own voice with its constants freed
        # (research-909-sound's structure kick), fitted by CMA-ES under the
        # round 3 ear loss (research-voice-match-3, fit909_r3.rb
        # kick_thejames_l3), the maintainer's pick of the round-4 Bench
        # (2026-11-04).  Knobs read as on the tr909's kick (tune Hz, decay
        # s, punch the pitch sweep / 5, drive the gain 2^(2 drive), attack
        # the click / 0.9) plus drop (the slow pitch drop) and tick (the
        # noise tick); the defaults are the fitted numbers, written as the
        # fit printed them, and their ranges the fit's search ranges.
        # Plays bit for bit like the fit's console code (fits_spec).
        def fit909_kick
          @fit909_kick ||= Drums.machine(:fit909_kick) do
            voice :kick, tune: (30.0..110.0).at(51.328155), decay: (0.1..2.0).at(0.468972), punch: (0.0..2.0).at(2.061796 / 5),
                  drop: (0.0..0.8).at(0.283811), drive: (0.0..1.5).at(Math.log2(2.460364) / 2), attack: (0.0..1.5).at(0.732949 / 0.9),
                  tick: (0.0..1.5).at(0.562526), gm: TR909::GM_MAP[:kick], as: [:bd, :bass_drum] do |h|
              body = h.body(h.tune, decay: h.decay, sweep: h.punch * 5, sweep_time: 0.08, drop: h.drop, drop_time: 0.037723)
              drive = Drums.exp2(h.drive * 2)
              punch = (body * drive).softclip(0.205115, 1.0) * (1.25 / (1 + 0.25 * drive))
              tick = Drums.scale(h.noise(decay: 0.035986, highpass: 482.059, lowpass: 4882.476), h.tick)
              h.mix(punch, h.click(h.attack * 0.9, tone: 0.090532), tick)
            end
          end
        end

        # The fitted designs by name (Drums.designs).
        DESIGNS = { fit909_kick: -> { Fits.fit909_kick } }.freeze

        # The library entries' params: each voice's ranged knobs, named as
        # `bind :drums, kit: :kick_decay` names them.
        def params(name)
          DESIGNS.fetch(name).call.voices.flat_map { |v, spec|
            spec.params.map { |k, prm| n = :"#{v}_#{k}"; [n, MB::Sound::Param.new(name: n, default: prm.default, range: prm.range)] }
          }.to_h
        end
      end

      # The fitted 909 kick in the library (family :machine; the
      # maintainer's pick, 2026-11-04: "I like the round 3 kick -- save it
      # to the library").  settings[:voices] are the grid rows it plays
      # (auditions and Bench beats keep only those).  It builds through
      # `kit(source) { borrow :fit909_kick }`, so graphs record and save it
      # as written.
      Library.index.register(Library::Entry.new(
        name: :fit909_kick, kind: :kit, family: :machine, tags: %i[909 kick house techno],
        about: 'A 909 kick fitted to a recorded TR-909 house beat (CC BY-SA, measured only): the tr909 kick with its constants freed, fitted by CMA-ES to an ear loss',
        location: "lib/mb/sound/drums/fits.rb:#{Fits.method(:fit909_kick).source_location[1]}",
        settings: { voices: %i[kick] },
        params: -> { Fits.params(:fit909_kick) },
        builder: ->(source = nil, **kw) { MB::Sound.kit(source, name: :fit909_kick, **kw) { borrow :fit909_kick } }
      ))
    end
  end
end

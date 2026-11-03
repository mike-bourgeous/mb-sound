module MB
  module Sound
    # Hand-tuning tools (hand-tune-1, 2026-11-03; research-voice-match-3's
    # "hand-tune and infer" loop): the maintainer tunes a fitted sound by
    # ear in `design`, against its reference (`ab`), writing notes about
    # what he sees and hears (`ui.note`); an agent reads his take
    # (`take.turns`, Take::Reader) and renders his start and end states
    # to learn what his ears weighted.  The pieces: FitPatch (a fit as a
    # patch with named knobs), Reference (A/B), Take::Reader (his turns as
    # rows), UI::NoteLog (notes with what was on screen and the sound they
    # are about), and the offline renders here.
    module HandTune
      # The rate of offline renders.
      RATE = 48000

      module_function

      # One note of graph document +path+ rendered offline (a private
      # Session at the current tempo, master at 0 dB) with +values+ ({
      # param => value }) for +seconds+: an Array of SFloats (one per
      # channel) at 48 kHz.  The note is +note+ (a MIDI number) at
      # +velocity+, held +hold+ seconds (default 80% of +seconds+).  The
      # same values give the same samples (seeds are the document's).
      def render(path, values = {}, note: 60, velocity: 0.8, hold: nil, seconds: 1.0, channels: 1)
        bpm = Sequence.current_transport.bpm.to_f
        hold ||= seconds * 0.8
        len = Rational((hold * bpm / 240.0 * 4096).round.clamp(1, nil), 4096)
        clip = MB::Sound.seq(note).len(len).vel(velocity)
        frames = (seconds * RATE).round
        s = MB::Sound.keeping_random_state {
          MB::Sound.bounce(Rational(frames, RATE).seconds, bpm: bpm, channels: channels, gain: 1.0) { MB::Sound.preset(path, midi: clip, **values) }
        }
        s.to_a.map { |c| c[0...frames] }
      end

      # The comparison the infer step scores with: MB::Sound::Analysis's
      # (L3: round 2's spectral loss + 2 x the modulation spectrum + 0.3 x
      # the attack window) of +sound+ against +target+ (anything
      # Analysis::Signal.from takes: a path, a Sample, channels at
      # +sample_rate:+).  The one call site the loop's loss goes through,
      # so a tuned loss is a change here.  Returns an Analysis::Comparison
      # (#total, #terms).
      def compare(target, sound, seconds: nil)
        Analysis.compare(target, sound, seconds: seconds)
      end

      # A PNG of what a ui.note pointed at (+record+: a NoteLog record or
      # its path), drawn from the record's own data, offline: the RENDER
      # pane's envelope (time in seconds) and spectrum (Hz, dB), labeled,
      # with the note's spot as markers.  Writes +path+ (default: beside
      # the record, .png) and returns it.
      def note_image(record, path: nil)
        rec = record.is_a?(Hash) ? record : UI::NoteLog.read(record)
        path ||= record.is_a?(String) ? record.sub(/\.json\z/, '.png') : raise(ArgumentError, 'note_image needs path: for a record Hash')
        r = rec[:render] or raise ArgumentError, "the note has no render data (it was written without the sound screen's RENDER pane)"
        pt = rec[:pointed] || {}
        plot = MB::Sound::Plot
        charts = []
        if (env = r[:envelope])
          xs = Numo::DFloat.linspace(0, env[:seconds], env[:hi].length)
          charts << plot.chart(title: "#{rec.dig(:sound, :track)}: envelope (#{rec[:text].lines.first.strip[0, 60]})") { |b|
            b.x :linear, label: 'time', unit: 's'
            b.y :symmetric, label: 'level'
            b.area(Numo::DFloat.cast(env[:hi].map { |v| v || 0 }), x: xs, base: 0.0, color: 0)
            b.area(Numo::DFloat.cast(env[:lo].map { |v| v || 0 }), x: xs, base: 0.0, color: 0)
            b.rule(x: pt[:seconds], color: '#e5c07b') if pt[:seconds]
          }
        end
        if (sp = r[:spectrum])
          charts << plot.chart(title: 'spectrum') { |b|
            b.x :frequency, 20.0..sp[:hz].compact.max.to_f
            b.y :db
            b.line(Numo::DFloat.cast(sp[:db].map { |v| v || -120 }), x: Numo::DFloat.cast(sp[:hz]))
            b.rule(x: pt[:hz], color: '#e5c07b') if pt[:hz]
          }
        end
        plot.figure(*charts, columns: 1).save(path, width: 1000)
        path
      end

      # A comparison image (Analysis.look: waveform, first 50 ms,
      # spectrogram, top octaves) of the patch a ui.note was about, at the
      # note's knobs (rendered offline from its graph document), beside its
      # reference: what an agent reads next to his words.  Writes +path+
      # (default: beside the record, _look.png) and returns it.
      def note_look(record, path: nil, seconds: 1.0)
        rec = record.is_a?(Hash) ? record : UI::NoteLog.read(record)
        path ||= record.is_a?(String) ? record.sub(/\.json\z/, '_look.png') : raise(ArgumentError, 'note_look needs path: for a record Hash')
        snd = rec[:sound] or raise ArgumentError, 'the note is about no track'
        doc = snd.dig(:instrument, :path) or raise ArgumentError, "the note's track plays no graph document (fit_patch or a preset)"
        n = snd[:note] || {}
        sounds = { 'patch' => render(doc, snd[:params] || {}, note: n[:number] || 60, velocity: n[:velocity] || 0.8, hold: n[:hold], seconds: seconds) }
        ref = snd.dig(:reference, :source)
        sounds['reference'] = ref if ref && File.exist?(ref.to_s)
        Analysis.look(sounds.transform_values { |v| v.is_a?(Array) ? v.first : v }, path: path, seconds: seconds)
      end

      # What `tune` opened: +track+, +fit+ (FitPatch::Patch), +opened+
      # (UI::Design::Opened, or nil without a screen), +pair+
      # (Reference::Pair, or nil without a reference).
      Opened = Data.define(:track, :fit, :opened, :pair) do
        def to_s
          [fit.to_s, opened&.to_s, pair&.to_s, "turn by ear, ab (or b) to compare, ui.note 'what you hear', take.save :tmp, 'tuned #{track}'"].compact.join("\n")
        end

        def inspect = "#<HandTune::Opened #{track.inspect}: #{fit.name}#{pair ? ", reference #{pair.source}" : ''}>"
      end

      # Loads a fitted sound for hand-tuning in one line (see
      # HandTuneMethods#tune).  Returns an Opened.
      def tune(track, code, ref: nil, play: nil, as: nil, **params)
        raise ArgumentError, "tune names a track: tune :kick, code, ref: 'kick.wav', tune: (30.0..110.0).at(51.3), ..." unless track.is_a?(Symbol)
        fit = FitPatch.save(as || :"#{track}_fit", code, params)
        opened = UI::Design.open(track, fit, *[play].compact)
        pair = ref ? Reference.setup(Session.current, track, ref) : nil
        Opened.new(track: track, fit: fit, opened: opened, pair: pair)
      end
    end

    # The console's tune (MB::Sound extends it; hand-tune-1).
    module HandTuneMethods
      # Loads a fitted sound for hand-tuning in one line: the fit's voice
      # +code+ (console Ruby with its numbers as literals) and its params
      # with the fit's ranges become a patch with named knobs
      # (fit_patch, as :<track>_fit unless +as:+), opened on track
      # +track+ in the sound-design screen (design, playing the clip
      # +play:+, else its role's note), with the reference +ref:+ (a file
      # or a Sample)
      # on its own track for A/B (ab, or b in the inspector),
      # loudness-matched.  Every other keyword is a fitted number,
      # `(lo..hi).at(value)` (fits name params like `clip`, so the options
      # are ref:, play:, and as:).  Returns a HandTune::Opened (it prints
      # what it did and what to do next).
      #
      #     tune :kick, "kit(grid(16, kick: 'X...'), seed: 1) { voice(:kick) { |h| ... } }", ref: 'kick.wav',
      #       tune: (30.0..110.0).at(51.33), decay: (0.1..2.0).at(0.469)
      #     # turn by ear; ab to compare; ui.note 'the click is late'; take.save :tmp, 'tuned kick'
      def tune(track, code, ref: nil, play: nil, as: nil, **params)
        HandTune.tune(track, code, ref: ref, play: play, as: as, **params)
      end
    end

    extend HandTuneMethods
  end
end

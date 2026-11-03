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
        len = Rational((Sequence::TempoMap.whole_notes_at(hold, bpm) * 4096).round.clamp(1, nil), 4096)
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
      # (#total, #terms).  +weights:+ replaces L3's (refine's option).
      def compare(target, sound, seconds: nil, weights: Analysis::Comparison::WEIGHTS)
        Analysis.compare(target, sound, seconds: seconds, weights: weights)
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

      # One step of his path scored (see .infer): +row+ (the take's
      # Take::Reader::Turn), +before+ and +after+ (the comparison's total
      # before and after the step), +terms+ ({ term => change }: negative
      # is closer), +agrees+ (true when the loss fell or held within
      # +tolerance+, false when it calls his step worse).
      # A step whose +row+ is a Take::Reader::Structure is a redefinition
      # (retune): its loss change is the structure's own effect, at the
      # knobs he had.
      Step = Data.define(:row, :before, :after, :terms, :agrees) do
        # True for a redefinition's step.
        def structure? = row.is_a?(Take::Reader::Structure)

        def to_s
          t = terms.map { |k, d| "#{k} #{format('%+.3f', d)}" }.join(', ')
          what = structure? ? "#{row.track}  structure #{[*row.added.map { |p| "+#{p}" }, *row.removed.map { |p| "-#{p}" }].join(' ')}".rstrip :
                              "#{row.knob}  #{Take::Reader.number(row.from)} -> #{Take::Reader.number(row.to)}"
          "#{format('%8.3f', row.seconds.to_f)} s  #{what}  " \
            "loss #{format('%.3f', before)} -> #{format('%.3f', after)} (#{t})  #{agrees ? 'agrees' : 'DISAGREES'}"
        end
      end

      # One stretch of his path played by one version of the patch
      # (between redefinitions): +document+ (its path), +start+ and +finish+
      # (the comparisons where it began and ended), +line+ (the straight
      # line between, as Inference#line).
      Segment = Data.define(:document, :start, :finish, :line)

      # What .infer found: +steps+ (Steps), +start+ and +finish+ (the
      # comparison at his start and end), +line+ ([[fraction, total], ...]:
      # the straight line from his start to his end, which a loss that
      # agrees with him falls along), +track+.
      #
      # +segments+ (Segments) split the path at redefinitions (retune); +line+
      # is the last one's.  A redefinition is a Step of its own.
      Inference = Data.define(:track, :steps, :start, :finish, :line, :segments) do
        # His steps the loss calls worse.
        def disagreements = steps.reject(&:agrees)

        # The terms' change from his start to his end ({ term => change }):
        # negative ones got closer (what he listened for), positive ones he
        # gave up.
        def weighted = start.terms.to_h { |k, v| [k, finish.terms[k] - v] }

        # True if the loss falls along the straight line from start to end
        # (of the last segment).
        def monotone? = line.each_cons(2).all? { |(_, a), (_, b)| b <= a + 1e-9 }

        # The redefinitions' steps.
        def structures = steps.select(&:structure?)

        def to_s
          w = weighted.map { |k, d| "#{k} #{format('%+.3f', d)}" }.join(', ')
          lines = segments.each_with_index.map { |sg, i|
            mono = sg.line.each_cons(2).all? { |(_, a), (_, b)| b <= a + 1e-9 }
            label = segments.length > 1 ? "segment #{i + 1} (#{File.basename(sg.document)})" : 'the straight line start -> end'
            "along #{label}: #{sg.line.map { |f, v| "#{(f * 100).round}% #{format('%.3f', v)}" }.join(', ')}#{mono ? '' : ' (not falling all the way)'}"
          }
          [
            "#{track}: loss #{format('%.3f', start.total)} at his start, #{format('%.3f', finish.total)} at his end (#{w})",
            "the loss agrees with #{steps.count(&:agrees)} of his #{steps.length} steps#{disagreements.empty? ? '' : '; calls worse:'}",
            *disagreements.map { |st| "  #{st}" },
            *lines,
            'every step:', *steps.map { |st| "  #{st}" },
          ].join("\n")
        end

        def inspect = "#<HandTune::Inference #{track}: #{disagreements.length} of #{steps.length} steps disagree>"
      end

      # The infer step (prototype; research-voice-match-3's hand-tune loop,
      # step 4): scores every state along the maintainer's path through a
      # take (+turns+, a Take::Reader::Result) for +track+'s graph document
      # with the comparison (.compare: L3) against +reference+ (a path, a
      # Sample, channels at 48 kHz), and reports where the loss disagrees
      # with him: his steps it calls worse.  Each state is one note
      # (+note+, +velocity+, +hold+, +seconds+) rendered offline from the
      # document at that state's params (.render): the same values, the
      # same samples.  +line+ fractions of the straight line from his start
      # to his end (in each param's range and curve: Param#position) are
      # scored too.  Turns of knobs that aren't the document's params
      # (levels) are left out: the comparison is level-free.  A loss tuned
      # to agree with him changes .compare.  Returns an Inference.
      #
      #     t = take.turns
      #     puts HandTune.infer(t, track: :kick, reference: 'kick_ref.wav', note: 36, seconds: 0.5)
      #
      # A take that redefined the patch (retune; Take::Reader::Structure)
      # is scored in segments, one per version of the document: the
      # redefinition is a step of its own (the loss at his knobs before it,
      # then in the new structure at the knobs it carried: the structure's
      # own effect), and each segment has its straight line.
      def infer(turns, track:, reference:, note: 60, velocity: 0.8, hold: nil, seconds: 1.0, tolerance: 1e-6, line: [0.25, 0.5, 0.75])
        path = turns.document(track, :start)
        doc = GraphIO.parse(path)
        knob_of = ->(d) { d.params.keys.to_h { |p| [Session::Name.param(track, p), p] } }
        names = knob_of.(doc)
        state = turns.values(track, :start)
        score = ->(at, values) { compare(reference, render(at, values, note: note, velocity: velocity, hold: hold, seconds: seconds)[0], seconds: seconds) }
        # (the straight line from +a+ to +b+ in document +d+ at +at+)
        segment = ->(at, d, a, b, from, to) {
          pts = [[0.0, from.total]] + Array(line).map { |f|
            v = d.declarations.to_h { |p, decl|
              pa = decl.position(a[p]).to_f
              pb = decl.position(b[p]).to_f
              [p, decl.value(pa + (pb - pa) * f)]
            }
            [f.to_f, score.(at, v).total]
          } + [[1.0, to.total]]
          Segment.new(document: at, start: from, finish: to, line: pts.freeze)
        }
        start = score.(path, state)
        prev = start
        seg = [state, start]
        segments = []
        steps = turns.events.filter_map { |row|
          if row.is_a?(Take::Reader::Structure)
            next unless row.track == track && row.version
            segments << segment.(path, doc, seg[0], state, seg[1], prev)
            old = doc.declarations
            path = row.version.path
            doc = GraphIO.parse(path)
            names = knob_of.(doc)
            # (as TrackKnobs gives them: kept knobs moved from their param's
            # value keep it unless the new range leaves it out, others and
            # added ones take the new params' values)
            state = doc.declarations.to_h { |p, decl|
              v = state[p]
              moved = old[p] && v.is_a?(Numeric) && v != old[p].default
              [p, moved && !row.reset.key?(p) ? v : decl.default]
            }
          else
            next if row.kind == :reset # (in the structure's step)
            p = names[row.knob] or next
            next if row.to.nil?
            state = state.merge(p => row.to)
          end
          now = score.(path, state)
          terms = now.terms.to_h { |k, v| [k, v - prev.terms[k]] }
          st = Step.new(row: row, before: prev.total, after: now.total, terms: terms, agrees: now.total <= prev.total + tolerance)
          seg = [state, now] if row.is_a?(Take::Reader::Structure)
          prev = now
          st
        }
        finish = prev
        segments << segment.(path, doc, seg[0], state, seg[1], finish)
        Inference.new(track: track, steps: steps.freeze, start: start, finish: finish, line: segments.last.line, segments: segments.freeze)
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
        o = HandTune.tune(track, code, ref: ref, play: play, as: as, **params)
        HandTune::Worker.prepare if MB::Sound.live? # (refine's worker loads while he turns knobs)
        puts o.to_s # (a pasted one-liner may end with another line: say what it did either way)
        o
      end
    end

    extend HandTuneMethods
  end
end

require_relative 'hand_tune/retune'
require_relative 'hand_tune/cmaes'
require_relative 'hand_tune/search'
require_relative 'hand_tune/refine_job'
require_relative 'hand_tune/worker'
require_relative 'hand_tune/refine'

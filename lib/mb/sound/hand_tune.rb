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
    end
  end
end

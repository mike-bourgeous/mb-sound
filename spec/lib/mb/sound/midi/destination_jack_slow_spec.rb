# The slow tier of MIDI out on JACK's first-note timing (tagged :slow,
# SLOW=1 only; destination_jack_spec.rb has the everyday sweep and
# destination_jack_late_spec.rb the forced late first write): the first notes of a fresh output in 120
# starts at five buffer sizes, for a note on the first frame and one a 16th
# in, the first buffer rendered densely near the end of the JACK period
# (and at its start), where the first write most often comes after the
# next cycle.  No note may be off at any start (midi-out-first-note: before
# its fix, 983 of 1000 starts sent the first note 256 frames ahead of its
# audio; midi-out-first-note-2: after it, still 10 of 200 starts in the
# period's last eighth on an idle machine, and 7 of 80 here in a loaded
# run of the suite).
require_relative '../../../../support/jack_midi_out_timing'

RSpec.describe('MIDI out on JACK (first notes, many starts)', :aggregate_failures, :slow) do
  include_context 'JACK MIDI out timing'

  it 'sends the first notes with their audio in 120 starts at five buffer sizes' do
    [0r, 1/16r].each do |start|
      sweep(start, sizes: [128, 256, 400, 512, 1024], phases: [0, 224, 236, 244, 248, 252], rounds: 2)
    end
  end
end

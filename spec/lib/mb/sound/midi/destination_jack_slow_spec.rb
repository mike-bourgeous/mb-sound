# The slow tier of MIDI out on JACK's first-note timing (tagged :slow,
# SLOW=1 only; destination_jack_spec.rb has the everyday sweep): the first
# notes of a fresh output in 80 starts, between the everyday phases, at
# five buffer sizes, for a note on the first frame and one a 16th in.  No
# first note may be off by a period at any start (midi-out-first-note:
# before the fix, 983 of 1000 starts sent the first note 256 frames ahead
# of its audio).
require_relative '../../../../support/jack_midi_out_timing'

RSpec.describe('MIDI out on JACK (first notes, many starts)', :aggregate_failures, :slow) do
  include_context 'JACK MIDI out timing'

  it 'sends the first notes with their audio in 80 starts at five buffer sizes' do
    [0r, 1/16r].each do |start|
      sweep(start, sizes: [128, 256, 400, 512, 1024], phases: [32, 96, 160, 224], rounds: 2)
    end
  end
end

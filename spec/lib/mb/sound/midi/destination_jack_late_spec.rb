# MIDI out on JACK when the Session's audio is written late, as a busy
# machine makes it (midi-out-first-note-2): the first write after a JACK
# cycle went by with the output's ring still empty, and an underrun with
# notes of the late buffer already sent.  Forced by holding a write
# (spec/support/jack_midi_out_timing.rb, #play's hold:), so they fail
# without the fix on an idle machine too.  The everyday timing proof:
# destination_jack_spec.rb.
require_relative '../../../../support/jack_midi_out_timing'

RSpec.describe('MIDI out on JACK (late writes)', :aggregate_failures) do
  include_context 'JACK MIDI out timing'

  # What a busy machine does to a start: the render thread is descheduled
  # after the first notes were sent and before the first audio is written,
  # so a JACK cycle passes with the ring still empty, the audio leaves a
  # period later than the clock said when the notes were sent, and notes
  # placed by that clock went a period early (midi-out-first-note-2: the
  # first note 256 frames early in 7 of 80 starts of the slow tier, in a
  # loaded run of the suite, and in 10 of 200 starts in the last eighth of
  # the period on an idle machine; forced here by holding the first write
  # until a cycle went by, 40 of 40 before the fix).
  it 'sends the first notes with their audio when the first write comes after a JACK cycle' do
    sweep(0r, sizes: [128, 400, 1024], phases: [0, 240], hold: :first)
  end

  # Notes rendered before an underrun, whose audio is written only after
  # the output ran dry: they go with their audio, through the gap and the
  # concealment landing on the late audio (midi-out-first-note-2; before,
  # they went early by the gap: 1777 frames here).  The notes are far
  # enough apart that the concealment's history before the gap holds no
  # click.  The forced gap is checked where the held write is and by its
  # size; another underrun of a busy machine (the output refilling from
  # empty after the forced one is the likely moment) is counted, not failed
  # on, since each note is still checked against its own audio
  # (jack-late-guard-1: a 128-frame unforced gap at 128-frame buffers failed
  # a loaded suite as "the audio had no gap"; 1 of 30 runs with 6 busy
  # loops on two CPUs, its notes all exact).
  [:silence, nil].each do |conceal|
    it "sends notes queued before an underrun with their audio (concealment #{conceal.inspect})" do
      clip = MB::Sound.seq(MB::Sound::C3, nil, nil, nil, MB::Sound::E3).n32
      [128, 400, 1024].each do |size|
        # (the write holding the second note's frame waits for the underrun)
        r = play(clip, size: size, bpm: 120, offset: 2.ms, frames: 24_000, start: 0r, hold: 12_000 / size, conceal: conceal)
        label = "#{size}-frame buffers"
        expect(r[:held]).to eq(true), label
        expect(r[:astats][:underruns]).to be >= 1, label
        expect(r[:astats][:concealed]).to be > 0, label if conceal.nil?
        expect(r[:sent].length).to eq(4), label
        expect_on_time(r, 96, label, gap: true)
        close_opened
      end
    end
  end

  # The harness's side of the above: an underrun the check isn't told
  # about, before or after the forced one, is counted and reported; the
  # notes still go with their audio.
  it 'counts an underrun the play did not force without failing, its notes with their audio' do
    clip = MB::Sound.seq(MB::Sound::C3, nil, nil, nil, MB::Sound::E3).n32
    [10, 105].each do |extra| # (writes between the first two notes, and the last two)
      r = play(clip, size: 128, bpm: 120, offset: 2.ms, frames: 24_000, start: 0r, hold: 12_000 / 128, unannounced: extra)
      label = "an extra underrun at write #{extra}"
      expect(r[:held]).to eq(true), label
      expect(r[:unannounced_held]).to eq(true), label
      expect(r[:astats][:underruns]).to be >= 2, label
      expect(r[:jumps].length).to be >= 2, "#{label}: #{r[:jumps].inspect}"
      gaps = @gaps
      expect_on_time(r, 96, label, gap: true)
      expect(@gaps).to eq(gaps + 1), label
      close_opened
    end
    expect(@gap_notes.length).to eq(2)
  end
end

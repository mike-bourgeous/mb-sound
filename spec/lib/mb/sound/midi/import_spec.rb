require_relative '../../../../support/midi_writer'

# MIDI files as clips and kits (midi-import-1).  Every file here is
# synthetic (spec/support/midi_writer.rb), reproducing features of real
# files: legato overlaps, dense CC lanes, no tempo event, tempo maps, GM
# drums in 6/8, odd meters, RPN bend ranges, controller-only clips.
RSpec.describe(MB::Sound::MIDI::Import) do
  let(:q) { 960 }
  let(:reese) { MidiWriter.reese_song(tmp_path('reese.mid')) }

  describe '#tracks' do
    it 'lists every track with its notes, kind, and controller lanes' do
      list = MB::Sound.midi_tracks(reese)
      expect(list.length).to eq(4)
      expect(list.map(&:name)).to eq(['Conductor', 'Unnamed', 'Unnamed', 'Pad'])
      expect(list[1]).to have_attributes(notes: 8, channels: [0], polyphony: 2, slides: 6, drums: false, controls: { cc1: 66, cc7: 1 })
      expect(list[3]).to have_attributes(polyphony: 3, slides: 0, controls: { bend: 2, pressure: 1 })
      text = list.inspect
      expect(text).to start_with('reese.mid: 180 BPM, 4/4')
      expect(text).to include('1 "Unnamed" ch 1, 8 notes As1..G2 poly 2 6 slides cc1 x66 cc7 x1')
      expect(text).to include('3 "Pad" ch 3, 6 notes As3..G4 poly 3 bend x2 pressure x1')
    end

    it 'says how many tempos a tempo map has' do
      expect(MB::Sound.midi_tracks(MidiWriter.rubato(tmp_path('r.mid'))).to_s.lines[0]).to include('8 tempos from 100 BPM')
    end
  end

  describe 'track selection' do
    it 'picks tracks by index, name, or a unique part of a name, ignoring case and NULs' do
      expect(MB::Sound.midi_clip(reese, track: 3).events.length).to eq(6)
      expect(MB::Sound.midi_clip(reese, track: 'pad').events.length).to eq(6)
      expect(MB::Sound.midi_clip(reese, track: :Pa).events.length).to eq(6)
    end

    it 'explains ambiguous, unknown, and missing choices with the tracks' do
      expect { MB::Sound.midi_clip(reese) }.to raise_error(ArgumentError, /2 tracks with notes: pick one with track: \(1 "Unnamed", 3 "Pad"\)/)
      expect { MB::Sound.midi_clip(reese, track: 'Unnamed') }.to raise_error(ArgumentError, /2 tracks .* match "Unnamed": pick one by index/)
      expect { MB::Sound.midi_clip(reese, track: 'Pdd') }.to raise_error(ArgumentError, /No track named "Pdd" .*did you mean "Pad"/)
      expect { MB::Sound.midi_clip(reese, track: 9) }.to raise_error(ArgumentError, /No track 9 .*tracks 0..3/)
      expect { MB::Sound.midi_clip(reese, track: 1, timing: :preformed) }.to raise_error(ArgumentError, /did you mean :performed/)
      expect { MB::Sound.midi_clip('x.wav') }.to raise_error(ArgumentError, /not a MIDI file/)
    end

    it 'asks for a channel when one track plays notes on several (format 0)' do
      path = MidiWriter.write(tmp_path('f0.mid'), conductor: false, tracks: [
        { channel: 0, notes: [[0, q, 36, 100], [q, 2 * q, 60, 90, 1]] },
      ])
      expect { MB::Sound.midi_clip(path) }.to raise_error(ArgumentError, /notes on channels 0, 1 \(0-based\): pick one with channel:/)
      expect(MB::Sound.midi_clip(path, channel: 1).events.map(&:value)).to eq([60])
    end
  end

  describe '#clip' do
    it 'places notes at exact whole notes from ticks, with velocities as played' do
      c = MB::Sound.midi_clip(reese, track: 1)
      expect(c).to be_looping
      expect(c).to be_performed
      expect(c.length).to eq(4r)
      expect(c.events.map(&:start)).to eq((0...8).map { |i| i * 1/2r })
      expect(c.events[0].velocity).to eq(90 / 127.0)
      expect(c.events.map(&:start)).to all(be_a(Rational))
    end

    it 'ends a re-struck key at the new note and keeps the second note to its own note-off' do
      c = MB::Sound.midi_clip(reese, track: 1)
      # (the first two notes are both C2; the first note-off comes after the second note-on)
      expect(c.events[0].length).to eq(1/2r)
      expect(c.events[1].length).to eq(1/2r + Rational(30, 4 * q))
    end

    it 'marks legato overlaps of a monophonic line as slides, keeping their lengths' do
      c = MB::Sound.midi_clip(reese, track: 1)
      expect(c.events.map { |e| !!e.slid }).to eq([false, true, true, true, true, true, true, false])
      expect(MB::Sound.midi_clip(reese, track: 1, slides: false).events.count(&:slid)).to eq(0)
    end

    it 'keeps chords and sustained arpeggios unmarked, and legato vs staccato pairs apart' do
      steps = (0...8).map { |i| i * q / 4 }
      legato = MidiWriter.write(tmp_path('legato.mid'), tracks: [{ notes: steps.each_with_index.map { |t, i| [t, t + q / 4 + q / 20, 46 + i % 3, 100] } }])
      staccato = MidiWriter.write(tmp_path('staccato.mid'), tracks: [{ notes: steps.each_with_index.map { |t, i| [t, t + q / 4, 46 + i % 3, 100] } }])
      arp = MidiWriter.write(tmp_path('arp.mid'), tracks: [{ notes: steps.each_with_index.map { |t, i| [t, t + q / 2, [57, 60, 64, 69][i % 4], 100] } }])
      expect(MB::Sound.midi_clip(legato).events.count(&:slid)).to eq(7)
      expect(MB::Sound.midi_clip(staccato).events.count(&:slid)).to eq(0)
      expect(MB::Sound.midi_clip(arp).events.count(&:slid)).to eq(0)
      expect(MB::Sound.midi_clip(arp, slides: true).events.count(&:slid)).to eq(7)
      expect(MB::Sound.midi_clip(reese, track: 'Pad').events.count(&:slid)).to eq(0)
      expect(MB::Sound.midi_tracks(arp)[1]).to have_attributes(polyphony: 2, slides: 0)
      # Per pair: a legato line keeps its slides around a chord, whose notes stay unmarked
      mixed = MidiWriter.write(tmp_path('mixed.mid'), tracks: [{ notes: [
        [0, q + 60, 40, 90], [q, 2 * q + 60, 43, 90], [2 * q, 3 * q, 48, 90], [2 * q, 3 * q, 52, 90], [3 * q, 4 * q, 45, 90],
      ] }])
      expect(MB::Sound.midi_clip(mixed).events.map { |e| !!e.slid }).to eq([true, false, false, false, false])
    end

    it 'takes the share of a note an overlap may reach as slides: (the :auto rule\'s half; gen-midi-2)' do
      steps = (0...8).map { |i| i * q / 4 }
      # Overlaps of a sixth of the note, and an arpeggio ringing half of each note into the next
      legato = MidiWriter.write(tmp_path('legato.mid'), tracks: [{ notes: steps.each_with_index.map { |t, i| [t, t + q / 4 + q / 20, 46 + i % 3, 100] } }])
      arp = MidiWriter.write(tmp_path('arp.mid'), tracks: [{ notes: steps.each_with_index.map { |t, i| [t, t + q / 2, [57, 60, 64, 69][i % 4], 100] } }])
      expect([0.1, 0.25, 0.5, :auto].map { |sl| MB::Sound.midi_clip(legato, slides: sl).events.count(&:slid) }).to eq([0, 7, 7, 7])
      expect([0.5, 1].map { |sl| MB::Sound.midi_clip(arp, slides: sl).events.count(&:slid) }).to eq([0, 7])
      [0, 1.5, -1, :all].each do |bad|
        expect { MB::Sound.midi_clip(legato, slides: bad) }.to raise_error(ArgumentError, /slides: is :auto, true, false, or the share/)
      end
    end

    it 'reads files without a tempo event in score time and rounds the loop up to whole bars' do
      path = MidiWriter.no_tempo_phrase(tmp_path('phrase.mid'))
      c = MB::Sound.midi_clip(path)
      expect(c.length).to eq(4r) # (the last note ends halfway through bar 4)
      expect(c.events.length).to eq(14)
      expect(c.events.last.start).to eq(13/4r)
    end

    it 'cuts phrases with from: and bars:, cutting notes at the end' do
      path = MidiWriter.no_tempo_phrase(tmp_path('phrase.mid'))
      c = MB::Sound.midi_clip(path, from: 1, bars: 2)
      expect(c.length).to eq(2r)
      expect(c.events.map(&:start)).to eq((0...8).map { |i| i * 1/4r })
      c = MB::Sound.midi_clip(path, from: 3, bars: 1, loop: false)
      expect(c).not_to be_looping
      expect(c.events.map { |e| [e.start, e.length] }).to eq([[0r, 1/4r], [1/4r, 1/2r]])
      expect { MB::Sound.midi_clip(path, from: 9) }.to raise_error(ArgumentError, /past the end/)
      expect { MB::Sound.midi_clip(path, bars: 0) }.to raise_error(ArgumentError, /bars:/)
    end

    it 'counts bars in the file meter, odd meters and changes included, at any ppqn' do
      [960, 24576].each do |ppqn|
        b = 4 * ppqn
        five = MidiWriter.write(tmp_path("five#{ppqn}.mid"), ppqn: ppqn, meters: [[0, 5, 4]],
                                tracks: [{ notes: (0...7).map { |i| [i * ppqn, (i + 1) * ppqn, 40, 90] } }])
        expect(MB::Sound.midi_clip(five).length).to eq(10/4r) # 7 beats -> 2 bars of 5/4
        seven = MidiWriter.write(tmp_path("seven#{ppqn}.mid"), ppqn: ppqn, meters: [[0, 7, 4]], tracks: [{ notes: [[b / 2, b, 40, 90]] }])
        expect(MB::Sound.midi_clip(seven).length).to eq(7/4r)
        expect(MB::Sound.midi_clip(seven).events[0].start).to eq(1/2r) # (a pickup rest stays)
      end
      drums = MidiWriter.drums_68(tmp_path('d.mid'))
      bass = MB::Sound.midi_clip(drums, track: 'Rolling Bass')
      expect(bass.length).to eq(27/8r) # 6/8 + 6/8 + 9/8 + 6/8
      expect(MB::Sound.midi_clip(drums, track: 'Rolling Bass', from: 2, bars: 1).length).to eq(9/8r)
      expect(MB::Sound.midi_clip(drums, track: 'Rolling Bass', from: 3, bars: 2).length).to eq(12/8r)
    end

    it 'holds notes through the sustain pedal unless sustain: false, which keeps the pedal as a lane' do
      path = MidiWriter.write(tmp_path('pedal.mid'), tracks: [{ notes: [[0, q / 2, 60, 90], [q, 3 * q / 2, 64, 90]], cc: [[0, 64, 127], [2 * q, 64, 0]] }])
      c = MB::Sound.midi_clip(path)
      expect(c.events.map(&:length)).to eq([1/2r, 1/4r])
      expect(c.controls).to eq([])
      dry = MB::Sound.midi_clip(path, sustain: false)
      expect(dry.events.map(&:length)).to eq([1/8r, 1/8r])
      expect(dry.control(64).points).to eq([[0r, 1.0], [1/2r, 0.0]])
    end

    it 'keeps controller lanes at exact positions, chasing values set before the window' do
      c = MB::Sound.midi_clip(reese, track: 1)
      cc1 = c.control(1)
      expect(cc1).to be_stepped
      expect(cc1.points.length).to eq(66)
      expect(cc1.points[1]).to eq([1r, 1 / 127.0])
      expect(c.control(:cc7).points).to eq([[3r, 100 / 127.0]])
      # Bar 3 (from 2): the ramp's last steps, then the jump to 120; cc7 not yet
      late = MB::Sound.midi_clip(reese, track: 1, from: 2, bars: 1)
      expect(late.control(1).points.values_at(0, -1)).to eq([[0r, 33 / 127.0], [5/16r, 120 / 127.0]])
      expect(late.control(7)).to be_nil
      # Bar 4 (from 3) starts with the fall's first step; a bar later, the
      # lanes' last values are chased to 0
      expect(MB::Sound.midi_clip(reese, track: 1, from: 3, bars: 1).control(1).points[0]).to eq([0r, 116 / 127.0])
      gone = MB::Sound.midi_clip(reese, track: 1, from: 4, bars: 1)
      expect(gone.controls.map { |l| [l.name, l.points] }).to eq([[:cc1, [[0r, 24 / 127.0]]], [:cc7, [[0r, 100 / 127.0]]]])
      expect(MB::Sound.midi_clip(reese, track: 1, cc: false).controls).to eq([])
      expect(MB::Sound.midi_clip(reese, track: 1, cc: [7]).controls.map(&:name)).to eq([:cc7])
      pad = MB::Sound.midi_clip(reese, track: 'Pad')
      expect(pad.controls.map(&:name)).to eq([:bend, :pressure])
      expect(pad.control(:bend).points).to eq([[1r, (4000 / 8191.0)], [1r + 1/8r, 0.0]])
    end

    it 'fits controller lanes with cc: :fit (a few keys within a 7-bit step)' do
      c = MB::Sound.midi_clip(reese, track: 1, cc: :fit)
      lane = c.control(1)
      expect(lane).not_to be_stepped
      expect(lane.points.length).to be < 12
      expect(lane.error).to be <= MB::Sound::Sequence::Clip::FIT_TOLERANCE
      steps = MB::Sound.midi_clip(reese, track: 1).control(1)
      steps.points.each_cons(2) do |(p, v), (p2, _)|
        # every step's value is within the tolerance of the curve where it was sent
        expect(lane.value_at(p)).to be_within(1.01 / 127).of(v)
      end
      # the jump to 120 (step 80) holds 40 until just before it
      expect(lane.value_at(2r + 1200 / 3840r - 1/64r)).to be_within(1.01 / 127).of(40 / 127.0)
    end

    it 'keeps the RPN bend range on the bend lane and sends it on launch' do
      path = MidiWriter.write(tmp_path('rpn.mid'), tracks: [{
        notes: [[0, q, 40, 90]], cc: [[0, 101, 0], [0, 100, 0], [1, 6, 12], [1, 38, 0], [1, 101, 127], [1, 100, 127]], bend: [[q / 2, 16383]],
      }])
      c = MB::Sound.midi_clip(path)
      expect(c.controls.map(&:name)).to eq([:bend])
      expect(c.control(:bend).range).to eq(12)
      events = c.stream.reader.next(1r)
      expect(events.first(4).map { |e| [e.note, e.raw] }).to eq([[101, 0], [100, 0], [6, 12], [38, 0]])
      expect(events.find(&:bend?).bend_semitones).to be_within(1e-9).of(12)
    end

    it 'imports controller-only clips (no notes) as lanes over whole bars' do
      ramp = (0...54).map { |k| [k * q * 48 / 54, 7, 7 + k * 2] }
      path = MidiWriter.write(tmp_path('vol.mid'), tracks: [{ name: 'volume ramp', cc: ramp }])
      c = MB::Sound.midi_clip(path)
      expect(c.events).to eq([])
      expect(c.length).to eq(12r)
      expect(c.control(7).points.length).to eq(54)
      expect(MB::Sound.midi_clip(path, cc: :fit).control(7).points.length).to be <= 4
    end

    it 'places events at the performed seconds with timing: :performed' do
      path = MidiWriter.rubato(tmp_path('rubato.mid'))
      score = MB::Sound.midi_clip(path)
      expect(score.events.map(&:start)).to eq((0...8).map { |i| i * 1/4r })
      performed = MB::Sound.midi_clip(path, timing: :performed)
      map = MB::Sound::MIDI::MIDIFile.new(path).tempo_map
      wnps = MB::Sound::Sequence.current_transport.whole_notes_per_second
      expect(performed.events.map(&:start)).to eq((0...8).map { |i| map.seconds(i * q) * wnps })
      expect(performed.length).to eq((performed.events.last.end_time / 1r).ceil * 1r)
    end
  end

  describe '#kit' do
    let(:drums) { MidiWriter.drums_68(tmp_path('drums.mid')) }

    it 'makes a Kit of GM drum rows from channel 10 and drum-named tracks, ignoring note lengths' do
      kit = MB::Sound.midi_kit(drums)
      expect(kit.rows.keys).to contain_exactly(:kick, :snare, :closed_hat, :open_hat)
      expect(kit[:kick].events.map(&:start)).to eq([0r, 3/8r, 6/8r, 9/8r, 12/8r, 15/8r, 21/8r, 24/8r].sort)
      expect(kit[:kick].length).to eq(27/8r)
      expect(kit[:closed_hat].events.map(&:length).uniq).to eq([MB::Sound::MIDI::Import::DRUM_HIT]) # (written 1/128)
      expect(kit[:open_hat].events.map(&:length)).to eq([MB::Sound::MIDI::Import::DRUM_HIT]) # (written 1/8)
      expect(MB::Sound.midi_kit(drums, track: 'kick1').rows.keys).to eq([:kick])
    end

    it 'plays through tr808 and tr909 like a grid' do
      kit = MB::Sound.midi_kit(drums, bars: 1)
      [MB::Sound.tr808(kit), MB::Sound.tr909(kit)].each do |g|
        out = SpecBuffers.join(Array.new(30) { g.sample(800).dup })
        expect(out.abs.max).to be > 0.05
      end
    end

    it 'leaves out notes without a drum name with a warning, and raises without drums' do
      path = MidiWriter.write(tmp_path('odd.mid'), tracks: [{ name: 'perc', channel: 9, notes: [[0, 60, 36, 100], [q, q + 60, 99, 100]] }])
      kit = nil
      expect { kit = MB::Sound.midi_kit(path) }.to output(/left out notes 99/).to_stderr
      expect(kit.rows.keys).to eq([:kick])
      expect { MB::Sound.midi_kit(reese) }.to raise_error(ArgumentError, /No drum tracks/)
    end
  end

  describe 'recipes and graph documents' do
    around { |ex| Dir.chdir(File.dirname(reese)) { ex.run } }

    it 'prints midi_clip calls as written and saves documents as events with controller lanes' do
      c = MB::Sound.midi_clip('reese.mid', track: 1, bars: 2, cc: :fit)
      g = c.transpose(2).synth(voices: 1) { |v| v.hz.saw * v.mod * v.amp_env }
      expect(g.to_ruby).to start_with('midi_clip("reese.mid", track: 1, bars: 2, cc: :fit).transpose(2).synth(voices: 1)')
      doc = MB::Sound::GraphIO.dump(g, name: :reese)
      expect(doc).not_to include('midi_clip')
      expect(doc).to include('events(', 'slid: true', 'controls: {', 'cc1: { curve: :linear, points: [')
      loaded = MB::Sound::GraphIO.load(doc)
      a = SpecBuffers.join(Array.new(20) { g.sample(800).dup })
      b = SpecBuffers.join(Array.new(20) { loaded.sample(800).dup })
      expect(b).to eq(a)
    end

    it 'saves kits from midi_kit as grid rows of events' do
      kit = MB::Sound.midi_kit(MidiWriter.drums_68('drums.mid'), bars: 1)
      doc = MB::Sound::GraphIO.dump(MB::Sound.tr808(kit), name: :beat)
      expect(doc).to include('tr808(grid(', 'kick: events(')
      expect(MB::Sound::GraphIO.load(doc)).to be_a(MB::Sound::Drums::Kit)
    end

    it 'loads midi_clip lines in documents and library files only with relative paths' do
      File.write('a.mbg.rb', %(graph 5, name: "a", kind: :graph\n\nmidi_clip("reese.mid", track: 1).synth(voices: 1) { |v| v.hz.saw * v.amp_env }\n))
      expect(MB::Sound::GraphIO.load('a.mbg.rb')).to be_a(MB::Sound::Synth)
      File.write('b.mbg.rb', %(graph 5, name: "b", kind: :graph\n\nmidi_clip("/etc/reese.mid", track: 1).synth(voices: 1) { |v| v.hz.saw * v.amp_env }\n))
      expect { MB::Sound::GraphIO.load('b.mbg.rb') }.to raise_error(MB::Sound::GraphIO::LoadError, /relative to the document/)
    end

    it 'loads clip lines of library files' do
      Dir.mkdir('shelf')
      MidiWriter.reese_song('shelf/riff.mid')
      File.write('shelf/riffs.rb', %(library 1\nclip :reese_riff, midi_clip("riff.mid", track: 1, bars: 2), tags: %i[bass]\n))
      entries = MB::Sound::Library::FileLoader.load('shelf/riffs.rb', shelf: MB::Sound::Library.shelf(:user))
      clip = entries.find { |e| e.name == :reese_riff }.builder.call
      expect(clip.length).to eq(2r)
    end
  end
end

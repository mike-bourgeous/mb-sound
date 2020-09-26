RSpec.describe MB::Sound::Note do
  describe '#initialize' do
    context 'when given a MIDI note number' do
      let!(:note_names) {
        [
          'C',
          'Cs',
          'D',
          'Ds',
          'E',
          'F',
          'Fs',
          'G',
          'Gs',
          'A',
          'As',
          'B'
        ]
      }

      (0..127).each_slice(12).each do |slice|
        context "for notes in #{slice.first}..#{slice.last}" do
          it "can create MIDI notes" do
            slice.each_with_index do |n, idx|
              note = MB::Sound::Note.new(n)
              octave = n / 12 - 1
              expect(note.name).to eq("#{note_names[idx]}#{octave}")
              expect(note.frequency.round(2)).to eq((440 * 2 ** ((n - 69) / 12.0)).round(2))
              expect(note.number).to eq(n)
            end
          end

          it 'preserves the MIDI note name and number when reconstructing from frequency' do
            slice.each_with_index do |n, idx|
              orig = MB::Sound::Note.new(n)
              note = MB::Sound::Note.new(orig.frequency.hz)
              expect(note.number).to eq(n)
              expect(note.name).to eq(orig.name)
            end
          end

          it 'preserves the MIDI note name and number when reconstructing from name' do
            slice.each_with_index do |n, idx|
              orig = MB::Sound::Note.new(n)
              note = MB::Sound::Note.new(orig.name)
              expect(note.number).to eq(n)
              expect(note.name).to eq(orig.name)
            end
          end

          it 'preserves the MIDI note name and number when reconstructing from number' do
            slice.each_with_index do |n, idx|
              orig = MB::Sound::Note.new(n)
              note = MB::Sound::Note.new(orig.number)
              expect(note.number).to eq(n)
              expect(note.name).to eq(orig.name)
            end
          end
        end
      end

      it 'can create fractional MIDI notes' do
        note = MB::Sound::Note.new(60.2)
        expect(note.detune).to eq(20)
        expect(note.name).to eq('C4')

        note = MB::Sound::Note.new(60.5)
        expect(note.detune).to eq(-50)
        expect(note.name).to eq('Cs4')

        note = MB::Sound::Note.new(60.51)
        expect(note.detune).to eq(-49)
        expect(note.name).to eq('Cs4')

        note = MB::Sound::Note.new(59.9)
      end

      (58..72).each do |n|
        [0.0, 0.1, 0.49, 0.5, 0.51, 0.9, 1.0].each do |d|
          number = n + d
          it "creates number and detuning that match note #{number}" do
            note = MB::Sound::Note.new(number)
            expect((note.number + note.detune * 0.01).round(2)).to eq(number)
          end
        end
      end

      it 'produces a Tone that can be played' do
        expect(MB::Sound::Note.new(56).generate(1000).max).not_to eq(0)
      end
    end

    context 'when given a Tone object' do
      let!(:hz) { MB::Sound::Note::TUNE_FREQ }
      let!(:n) { MB::Sound::Note::TUNE_NOTE }

      it 'finds octaves of the tuning reference' do
        expect(MB::Sound::Note.new(hz.hz).number).to eq(n)
        expect(MB::Sound::Note.new((hz * 2).hz).number).to eq(n + 12)
        expect(MB::Sound::Note.new((hz / 2).hz).number).to eq(n - 12)
      end

      it 'finds intervals from the tuning reference' do
        expect(MB::Sound::Note.new((hz * 1.25).hz).number).to eq(n + 4)
        expect(MB::Sound::Note.new((hz * 1.5).hz).number).to eq(n + 7)
      end

      it 'preserves attributes of the Tone' do
        n = MB::Sound::Note.new(hz.hz.ramp.at(-3.db).for(2.123))
        expect(n.wave_type).to eq(:ramp)
        expect(n.frequency.round(4)).to eq(hz.round(4))
        expect(n.duration).to eq(2.123)
        expect(n.amplitude).to eq(-3.db)
      end

      it 'produces a Tone that can be played' do
        expect(MB::Sound::Note.new(144.hz).generate(1000).max).not_to eq(0)
      end
    end

    context 'when given a note name' do
      it 'preserves the same note name and number for each MIDI note' do
        (0..127).each do |n|
          by_num = MB::Sound::Note.new(n)
          by_name = MB::Sound::Note.new(by_num.name)
          expect(by_name.name).to eq(by_num.name)
          expect(by_name.number).to eq(by_num.number)
        end
      end

      it 'can accept # or s for sharps' do
        expect(MB::Sound::Note.new('C#4').number).to eq(61)
        expect(MB::Sound::Note.new('Cs4').number).to eq(61)
      end

      it 'can translate a half-step accidental to the neighboring note' do
        expect(MB::Sound::Note.new('Cb4').name).to eq('B3')
        expect(MB::Sound::Note.new('Bs3').name).to eq('C4')
      end

      it 'can read small detuning amounts' do
        expect(MB::Sound::Note.new('D4+20').detune).to eq(20)
        expect(MB::Sound::Note.new('D4-20.1').detune).to eq(-20.1)

        n = MB::Sound::Note.new('D4-50')
        expect(n.detune).to eq(-50)
        expect(n.name).to eq('D4')

        n = MB::Sound::Note.new('D4+50')
        expect(n.detune).to eq(-50)
        expect(n.name).to eq('Ds4')
      end

      it 'can read large detuning amounts' do
        n = MB::Sound::Note.new('D4+99')
        expect(n.detune).to eq(-1)
        expect(n.name).to eq('Ds4')

        # The note name is rounded to the closest named note
        n = MB::Sound::Note.new('D4+101')
        expect(n.detune).to eq(1)
        expect(n.name).to eq('Eb4')

        n = MB::Sound::Note.new('D4-101')
        expect(n.detune).to eq(-1)
        expect(n.name).to eq('Cs4')

        n = MB::Sound::Note.new('Cs4-101')
        expect(n.detune).to eq(-1)
        expect(n.name).to eq('C4')

        n = MB::Sound::Note.new('D4-1200.5')
        expect(n.detune).to eq(-0.5)
        expect(n.name).to eq('D3')
      end

      it 'gives the right frequency for A4' do
        expect(MB::Sound::Note.new('A4').frequency.round(5)).to eq(440)
      end

      it 'produces a Tone that can be played' do
        expect(MB::Sound::Note.new('C4').generate(1000).max).not_to eq(0)
      end
    end
  end
end

RSpec.describe(MB::Sound::GainMethods) do
  describe '#normalize_max' do
    let(:loud_sound_orig) { Numo::SFloat[0.1, 0.3, 0.5, 2.5, 1.5].freeze }
    let(:quiet_sound_orig) { Numo::DFloat[0.2, 0.3, 0.4, 0.3].freeze }
    let(:both_orig) { [loud_sound_orig, quiet_sound_orig].freeze }
    let(:multi_orig) { [loud_sound_orig, quiet_sound_orig, quiet_sound_orig * 2, loud_sound_orig / 2].map(&:freeze) }
    let(:loud_sound) { loud_sound_orig.dup }
    let(:quiet_sound) { quiet_sound_orig.dup }
    let(:both) { [loud_sound, quiet_sound] }
    let(:multi) { multi_orig.map(&:dup) }

    it 'can normalize many channels at once' do
      result = MB::Sound.normalize_max(multi, 0.9)
      gain = 0.9 / 2.5
      expect(result).to eq(multi_orig.map { |c| c * gain })
    end

    it 'can normalize a standalone NArray' do
      expect(MB::Sound.normalize_max(loud_sound)).to be_a(Numo::NArray)
    end

    context 'when louder is false' do
      # Test various limits
      [0.75, 1.0, 1.5].each do |limit|
        context "with a limit of #{limit}" do
          let(:gain) { limit / 2.5 }

          it 'makes louder sounds quieter' do
            result = MB::Sound.normalize_max(loud_sound, limit)
            expect(result).to eq(loud_sound_orig * gain)
            expect(loud_sound).to eq(loud_sound_orig * gain)
          end

          it 'does not make quieter sounds louder' do
            result = MB::Sound.normalize_max(quiet_sound, limit)
            expect(result).to eq(quiet_sound_orig)
            expect(quiet_sound).to eq(quiet_sound_orig)
          end

          it 'uses the same amplification for all channels' do
            result = MB::Sound.normalize_max(both, limit)
            expect(result).to eq([loud_sound_orig * gain, quiet_sound_orig * gain])
            expect(loud_sound).to eq(loud_sound_orig * gain)
            expect(quiet_sound).to eq(quiet_sound_orig * gain)
          end
        end
      end

      context 'when no limit is given' do
        it 'uses a limit of 1.0' do
          result = MB::Sound.normalize_max(both)
          gain = 1.0 / 2.5
          expect(result).to eq([loud_sound_orig * gain, quiet_sound_orig * gain])
          expect(loud_sound).to eq(loud_sound_orig * gain)
          expect(quiet_sound).to eq(quiet_sound_orig * gain)
        end
      end
    end

    context 'when louder is true' do
      it 'raises a quieter sound to the default limit of 1.0' do
        MB::Sound.normalize_max(quiet_sound, louder: true)
        expect(quiet_sound).to eq(quiet_sound_orig * (1.0 / 0.4))
      end

      it 'raises a quieter sound to a different limit of 1.5' do
        MB::Sound.normalize_max(quiet_sound, 1.5, louder: true)
        expect(quiet_sound).to eq(quiet_sound_orig * (1.5 / 0.4))
      end

      it 'makes a louder sound quieter' do
        result = MB::Sound.normalize_max(loud_sound, 1.1, louder: true)
        gain = 1.1 / 2.5
        expect(result).to eq(loud_sound_orig * gain)
        expect(loud_sound).to eq(loud_sound_orig * gain)
      end

      it 'uses the same amplification for all channels' do
        MB::Sound.normalize_max(both, 4, louder: true)
        gain = 4 / 2.5
        expect(loud_sound).to eq(loud_sound_orig * gain)
        expect(quiet_sound).to eq(quiet_sound_orig * gain)
      end
    end

    context 'when louder is between 0 and 1' do
      context 'when no limit is given' do
        it 'makes a louder sound match the limit' do
          MB::Sound.normalize_max(both, louder: 0.5)
          gain = 1.0 / 2.5
          expect(loud_sound).to eq(loud_sound_orig * gain)
          expect(quiet_sound).to eq(quiet_sound_orig * gain)
        end

        it 'makes a quieter sound louder, but not to the limit' do
          MB::Sound.normalize_max(quiet_sound, louder: 0.5)
          gain = 0.5 + 0.5 * (1.0 / 0.4)
          expect(quiet_sound).to eq(quiet_sound_orig * gain)
        end
      end

      context 'when a custom limit is given' do
        it 'makes a louder sound match the limit' do
          MB::Sound.normalize_max(both, 2.0, louder: 0.25)
          gain = 2.0 / 2.5
          expect(loud_sound).to eq(loud_sound_orig * gain)
          expect(quiet_sound).to eq(quiet_sound_orig * gain)
        end

        it 'makes a quieter sound louder, but not to the limit' do
          MB::Sound.normalize_max(both, 4.5, louder: 0.25)
          gain = 0.75 + 0.25 * (4.5 / 2.5)
          expect(loud_sound).to eq(loud_sound_orig * gain)
          expect(quiet_sound).to eq(quiet_sound_orig * gain)
        end
      end
    end

    context 'when louder is greater than 1' do
      it 'makes a louder sound match the limit' do
        MB::Sound.normalize_max(both, 2.0, louder: 0.25)
        gain = 2.0 / 2.5
        expect(loud_sound).to eq(loud_sound_orig * gain)
        expect(quiet_sound).to eq(quiet_sound_orig * gain)
      end

      it 'makes a quieter sound louder than the limit' do
        MB::Sound.normalize_max(quiet_sound, 1.5, louder: 2)
        gain = -1 + 2 * (1.5 / 0.4)
        expect(quiet_sound).to eq(quiet_sound_orig * gain)
        expect(quiet_sound.max).to be > 1.5
      end
    end
  end

  describe '#normalize_max_sum' do
    let(:less_than_one_orig) { Numo::SFloat[0.25, 0.5, 0.125].freeze }
    let(:greater_than_one_orig) { Numo::SFloat[0.5, 0.5, 0.75].freeze }
    let(:less_than_one) { less_than_one_orig.dup }
    let(:greater_than_one) { greater_than_one_orig.dup }

    it 'can use a custom limit' do
      MB::Sound.normalize_max_sum([less_than_one], 0.4375)
      expect(less_than_one).to eq(less_than_one_orig * 0.5)
    end

    it 'makes louder sounds quieter' do
      MB::Sound.normalize_max_sum([greater_than_one])
      expect(MB::M.round(greater_than_one, 6)).to eq(MB::M.round(greater_than_one_orig * (1.0 / 1.75), 6))
    end

    it 'does not make quieter sounds louder' do
      MB::Sound.normalize_max_sum([less_than_one])
      expect(less_than_one).to eq(less_than_one_orig)
    end

    it 'does not use the same gain for each channel' do
      MB::Sound.normalize_max_sum([greater_than_one, less_than_one])
      expect(MB::M.round(greater_than_one, 6)).to eq(MB::M.round(greater_than_one_orig * (1.0 / 1.75), 6))
      expect(less_than_one).to eq(less_than_one_orig)
    end
  end
end

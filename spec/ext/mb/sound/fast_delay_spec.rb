require 'shellwords'

RSpec.describe('MB::Sound::FastDelay', :aggregate_failures) do
  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_delay.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastDelay.respond_to?(:read)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    # Last line only: under `rake memcheck` (RUBY_FREE_AT_EXIT=1) Ruby
    # first warns "Free at exit is experimental".
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  describe '.read' do
    let(:buffer) { Numo::SFloat.new(64).seq }

    it 'reads a delayed block into the target' do
      target = Numo::SFloat.zeros(4)
      expect(MB::Sound::FastDelay.read(buffer, target, 10, 2, 0, nil, nil)).to equal(target)
      expect(target.to_a).to eq([8, 9, 10, 11])
    end

    it 'rejects buffers and targets of the wrong type' do
      expect { MB::Sound::FastDelay.read(Numo::DFloat.zeros(64), Numo::DFloat.zeros(4), 0, 1, 0, nil, nil) }.to raise_error(ArgumentError, /SFloat or SComplex/)
      expect { MB::Sound::FastDelay.read(buffer, Numo::SComplex.zeros(4), 0, 1, 0, nil, nil) }.to raise_error(ArgumentError, /buffer's type/)
    end

    it 'rejects unknown modes, missing sinc kernels, and buffers too small for the mode' do
      target = Numo::SFloat.zeros(4)
      expect { MB::Sound::FastDelay.read(buffer, target, 0, 1, 7, nil, nil) }.to raise_error(ArgumentError, /mode/)
      expect { MB::Sound::FastDelay.read(buffer, target, 0, 1, 2, nil, nil) }.to raise_error(ArgumentError, /kernel/)
      expect { MB::Sound::FastDelay.read(Numo::SFloat.zeros(8), target, 0, 1, 2, MB::Sound::DelayLine::SINC_KERNEL, nil) }.to raise_error(ArgumentError, /too small/)
    end
  end

  describe '.feedback' do
    it 'returns the new write offset' do
      buffer = Numo::SFloat.zeros(64)
      out = Numo::SFloat.zeros(10)
      expect(MB::Sound::FastDelay.feedback(buffer, 60, Numo::SFloat.ones(10), out, 3, 0.5, 0, nil, nil)).to eq(6)
    end

    it 'rejects complex feedback on a real buffer' do
      expect {
        MB::Sound::FastDelay.feedback(Numo::SFloat.zeros(64), 0, Numo::SFloat.ones(4), Numo::SFloat.zeros(4), 1, 0.5i, 0, nil, nil)
      }.to raise_error(ArgumentError, /complex/i)
    end
  end
end

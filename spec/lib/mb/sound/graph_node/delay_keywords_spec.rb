# delay(seconds:) deprecation and the smooth: spelling (research-api-surface
# R2 and R3; maintainer decision 2026-10-13).
RSpec.describe(MB::Sound::GraphNode::DelayMethods) do
  describe 'seconds:' do
    it 'warns once per call site and still sets the time' do
      nodes = []
      expect {
        2.times { nodes << 1.constant.delay(seconds: 0.25) }
      }.to output(/#{Regexp.escape(File.basename(__FILE__))}:\d+: warning: delay\(seconds: t\) is deprecated; write delay\(t\)/).to_stderr
      expect(nodes.map { |n| n.base_filter.delay_samples }).to eq([12000, 12000])

      expect { 1.constant.delay(seconds: 0.25) }.to output(/deprecated/).to_stderr # another line, another warning
    end

    it 'loads silently from graph documents' do
      text = "graph 1, name: 'echo'\n1.constant.delay(seconds: 0.25)\n"
      g = nil
      expect { g = MB::Sound::GraphIO.load(text) }.not_to output.to_stderr
      expect(g.base_filter.delay_samples).to eq(12000)
    end

    it 'exports as a positional time' do
      g = nil
      expect { g = 1.constant.delay(seconds: 0.25, smoothing: false) }.to output(/deprecated/).to_stderr
      expect(g.to_ruby).to include('delay(0.25, smooth: false)')
    end
  end

  # (delays-2: the maintainer's "Equal power", 2026-10-30)
  describe 'mix:' do
    def impulse_out(g, n = 300)
      SpecBuffers.join(Array.new(n / 100) { g.sample(100)&.dup }.compact)
    end

    it 'crossfades dry and wet at equal power, with and without feedback, numbers or nodes' do
      imp = -> { 1.constant.until(1.samples).and_then(MB::Sound.silence(0.01)) }
      [{}, { feedback: 0.5 }].each do |fb|
        out = impulse_out(imp.().delay(100.samples, mix: 0.25, **fb))
        expect(out[0]).to be_within(1e-6).of(Math.sqrt(0.75)), fb.inspect
        expect(out[100]).to be_within(1e-6).of(0.5), fb.inspect
        node = impulse_out(imp.().delay(100.samples, mix: 0.25.constant, **fb))
        expect((node - out).abs.max).to be < 1e-6, fb.inspect
      end
      # dry: and wet: scale the crossfade; mix: 0 and 1 are all dry and all wet
      out = impulse_out(imp.().delay(100.samples, mix: 1, dry: 0.5, wet: 0.5))
      expect([out[0], out[100]]).to eq([0, 0.5])
      out = impulse_out(imp.().delay(100.samples, mix: 0))
      expect([out[0], out[100]]).to eq([1, 0])
    end

    it 'prints back as given' do
      expect(1.constant.delay(0.1, feedback: 0.4, mix: 0.3).to_ruby).to eq('1.constant.delay(0.1, feedback: 0.4, mix: 0.3)')
    end
  end

  describe 'smooth:' do
    it 'is the same option as smoothing:' do
      expect(1.constant.delay(0.1, smooth: false).base_filter.smoothing).to eq(false)
      expect(1.constant.delay(0.1, smoothing: false).base_filter.smoothing).to eq(false)
      expect(1.constant.delay(0.1).base_filter.smoothing).to eq(true)
      expect(1.n8.delay(smooth: false).smoothing).to eq(false)
    end

    it 'refuses both spellings at once' do
      expect { 1.constant.delay(0.1, smooth: false, smoothing: false) }.to raise_error(ArgumentError, /not both/)
    end

    it 'works on multitap' do
      taps = 1.constant.multitap(0.1, 0.2, smooth: true)
      expect(taps.to_a.length).to eq(2)
      expect { 1.constant.multitap(0.1, smooth: true, smoothing: true) }.to raise_error(ArgumentError, /not both/)
    end
  end
end

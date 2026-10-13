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

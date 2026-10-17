# The inspection protocol (racks R1, design/notes/racks.md): generic
# #params/#param_info, #plot_preview, snapshot spies, and MIDI::Stream#spy
# with Session stamps.
RSpec.describe('GraphNode inspection protocol') do
  let(:c4) { MB::Sound::C4 }
  let(:e4) { MB::Sound::E4 }

  describe '#params' do
    it 'lists a filter node\'s parameters, constants as numbers' do
      f = 110.hz.ramp.filter(:lowpass, cutoff: 800, quality: 4)
      expect(f.params).to eq(cutoff: 800, quality: 4)
      expect(f.param_info[:cutoff]).to include(value: 800, type: :control)
    end

    it 'gives nodes as they are, typed' do
      lfo = 3.hz.lfo.at(200..900)
      f = 110.hz.ramp.filter(:lowpass, cutoff: lfo)
      expect(f.params[:cutoff]).to be_a(MB::Sound::GraphNode)
      expect(f.param_info[:cutoff][:type]).to eq(:audio)
    end

    it 'describes knob readers with their range' do
      k = MB::Sound::GraphNode::Knob.new(:cut, 800, range: 100..8000)
      f = 110.hz.ramp.filter(:lowpass, cutoff: k)
      info = f.param_info[:cutoff]
      expect(info).to include(value: 800, range: 100..8000, label: :cut)
    end

    it 'leaves main inputs out' do
      expect(110.hz.ramp.softclip.params).to eq({})
    end

    it 'keeps ChannelMixer#params and adds declared ranges' do
      w = MB::Sound.stereo(110.hz.ramp, 220.hz.ramp).width(0.5)
      mixer = w.to_a[0].original_source rescue w.to_a[0].sources[:mixer]
      expect(mixer.params).to include(amount: 0.5)
      expect(mixer.param_info[:amount]).to include(value: 0.5)
    end
  end

  describe '#plot_preview' do
    it 'is nil by default' do
      expect(MB::Sound::Plot.preview(110.hz.ramp)).to be_nil
      expect(110.hz.ramp.plot_preview(nil)).to be_nil
    end

    it 'draws a filter response at the constant settings' do
      lp = MB::Sound::Plot.preview(110.hz.ramp.filter(:lowpass, cutoff: 800, quality: 4))
      expect(lp).to be_a(MB::Sound::Plot::Chart)
      line = lp.marks.find { |m| m.is_a?(MB::Sound::Plot::Mark::Line) }
      expect(line).not_to be_nil
      expect(lp.to_s).to be_a(String)

      f, db = MB::Sound::Plot::Presets.response_db(MB::Sound::Filter::SVF.new(:lowpass, 48000, 800, quality: 4), 48000)
      peak = f[db.max_index]
      expect(peak).to be_within(60).of(800)
      expect(db.max).to be_within(1).of(20 * Math.log10(4))
    end

    it 'draws a shaper transfer curve' do
      c = MB::Sound::Plot.preview(110.hz.ramp.softclip)
      expect(c).to be_a(MB::Sound::Plot::Chart)
      expect(c.marks.length).to eq(2)
    end
  end

  describe 'spy(snapshot: true)' do
    it 'hands each buffer frozen and kept' do
      got = []
      t = 110.hz.ramp.spy(snapshot: true) { |b| got << b }
      bufs = 3.times.map { t.sample(10).dup }
      expect(got.length).to eq(3)
      expect(got).to all(be_frozen)
      expect(got.map(&:__id__).uniq.length).to eq(3)
      expect(got).to eq(bufs)
    end

    it 'shares one copy among snapshot spies of a node' do
      a = []
      b = []
      t = 110.hz.ramp.spy(snapshot: true) { |x| a << x }.spy(snapshot: true) { |x| b << x }
      t.sample(10)
      expect(a[0]).to equal(b[0])
    end

    it 'works for nodes fused into a plan (Op::Tap)' do
      old = MB::Sound::Plan.enabled
      MB::Sound::Plan.enabled = true
      got = []
      inner = 110.hz.ramp.filter(:lowpass, cutoff: 800)
      inner.spy(snapshot: true) { |x| got << x }
      out = inner * 0.5
      MB::Sound::Plan.install(out)
      ref = []
      4.times { out.sample(64) }
      expect(got.length).to eq(4)
      expect(got).to all(be_frozen)
      expect(got.map(&:length).uniq).to eq([64])
      expect(ref).to eq([])
    ensure
      MB::Sound::Plan.enabled = old
    end
  end

  describe 'MIDI::Stream#spy' do
    it 'yields each event once, with nil stamps outside a Session' do
      st = MB::Sound.seq(c4, e4).n8.loop.stream
      seen = []
      st.spy { |e, at| seen << [e.type, e.time, at] }
      r1 = st.reader
      r2 = st.reader
      r1.next(0.5r)
      r2.next(0.5r)
      expect(seen.map(&:first)).to eq([:note_on, :note_off, :note_on]) # [0, 0.5): the second note-off is at 0.5 s
      expect(seen.map(&:last).uniq).to eq([nil])
    end

    it 'stamps events with the Session frame and position they land on' do
      sess = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, sleep: false))
      seen = []
      clip = MB::Sound.seq(c4, e4).n8.loop
      syn = clip.stream.spy { |e, at| seen << [e.type, at.frame, at.to_s] }.synth { |v| v.hz.ramp * v.amp_env }
      sess.add(syn, name: :x)
      40.times { sess.process_buffer }
      expect(seen.first(4)).to eq([[:note_on, 0, '1:1'], [:note_off, 12000, '1:1.5'], [:note_on, 12000, '1:1.5'], [:note_off, 24000, '1:2']])
    ensure
      sess&.close
      MB::Sound.rewind
    end

    it 'removes spies by handle' do
      st = MB::Sound.seq(c4).n8.loop.stream
      seen = []
      st.spy(handle: :a) { |e, _| seen << e }
      st.clear_spies(handle: :a)
      st.reader.next(1r)
      expect(seen).to be_empty
    end
  end
end

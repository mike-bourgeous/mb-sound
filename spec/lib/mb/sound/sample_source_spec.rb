# Samples' carried metadata (source-meta-1; Sample::Source, Meta): a file's
# own provenance under meta[:source], #with_meta, and what copies, views,
# saves, and documents keep.
RSpec.describe(MB::Sound::Sample::Source, :aggregate_failures) do
  let(:sample) { MB::Sound::Sample }
  let(:riff) { MB::Sound::Sample::Riff }
  let(:audio) { MB::Sound.with_seed(3) { Numo::SFloat.new(4800).rand - 0.5 } }
  let(:xm) { { format: :xm, kind: :sample, id: 4, at: 0x2a10, bytes: 9120, fields: { 'finetune' => -3, ratio: 3/4r, loop: [0, 1200] } } }

  def wav(name = 'loop_120bpm.wav', **options)
    path = tmp_path(name)
    riff.write(path, [audio], sample_rate: 44100, **options)
    path
  end

  describe 'a Sample read from a WAV file' do
    it 'brings the file\'s provenance: size, stored format, where the audio sits, every chunk, and what was not read' do
      path = wav(acid: { tempo: 120.0, beats: 4, one_shot: false }, extra: [['bext', 'x' * 10], ['junk', 'y' * 33]])
      s = sample[path]
      src = s.meta[:source]
      expect(src).to be_frozen
      expect(src.keys).to eq(%i[format file bytes sample_rate container channels bits frames data chunks chunk_count skipped unread])
      expect(src.slice(:format, :file, :bytes, :sample_rate, :container, :channels, :bits, :frames))
        .to eq(format: :wav, file: 'loop_120bpm.wav', bytes: File.size(path), sample_rate: 44100, container: :riff, channels: 1, bits: 16, frames: 4800)

      # the chunk list is the file's, byte for byte
      raw = File.binread(path)
      expect(src[:chunks].map(&:first)).to eq(['fmt ', 'acid', 'bext', 'junk', 'data'])
      src[:chunks].each do |id, at, size|
        expect(raw.byteslice(at, 4)).to eq(id)
        expect(raw.byteslice(at + 4, 4).unpack1('V')).to eq(size)
      end
      expect(src[:chunk_count]).to eq(5)
      expect(src[:data]).to eq(at: src[:chunks].last[1] + 8, bytes: 9600)
      expect(src[:skipped]).to eq(%w[bext junk])
      expect(src[:unread]).to eq((10 + 8) + (33 + 8))
      expect(MB::Sound::Meta.check(src)).to equal(src)
      expect(MB::Sound::Meta.summary(s.meta)).to start_with("from loop_120bpm.wav, #{MB::Sound::Meta.bytes_text(File.size(path))}, 59 bytes unread, + ")

      # the keys loop files had before stay as they were
      expect(s.meta.keys).to eq(%i[why smpl_loops source])
      expect(s.meta_source).to include(bpm: :acid)
      expect(s.bpm).to eq(120.0)
    end

    it 'reads the file no more often than before' do
      path = wav
      opens = []
      allow(File).to receive(:open).and_wrap_original { |m, *args, **kw, &blk| opens << args[0].to_s if args[0].to_s == path; m.call(*args, **kw, &blk) }
      allow(File).to receive(:binread).and_wrap_original { |m, *args, **kw| opens << args[0].to_s if args[0].to_s == path; m.call(*args, **kw) }
      sample.from_file_uncached(path)
      with_source = opens.length
      opens.clear
      allow(MB::Sound::Sample::Source).to receive(:add) { |kw, *_| kw }
      expect(sample.from_file_uncached(path).meta).not_to have_key(:source)
      expect(with_source).to eq(opens.length)
    end

    it 'counts nothing unread in a plain file, and lists at most CHUNKS_LISTED chunks' do
      s = sample[wav('plain.wav')]
      expect(s.meta[:source]).to include(skipped: [], unread: 0, chunk_count: 2)
      many = sample[wav('many.wav', extra: Array.new(70) { |i| ["x#{format('%03d', i)}", 'zz'] })]
      expect(many.meta[:source][:chunks].length).to eq(64)
      expect(many.meta[:source]).to include(chunk_count: 72, unread: 70 * 10)
      expect(many.meta[:source][:skipped].length).to eq(70)
    end

    it 'keeps a source the caller gives, and other files say their format and size' do
      path = wav('given.wav')
      given = sample[path, meta: { source: { format: :acd, kind: :media, id: 7 } }]
      expect(given.meta).to eq(source: { format: :acd, kind: :media, id: 7 })
      flac = sample['spec/test_data/arp_a7.flac']
      expect(flac.meta[:source]).to eq(format: :flac, file: 'arp_a7.flac', bytes: File.size('spec/test_data/arp_a7.flac'), sample_rate: 48000)
    end
  end

  describe '#with_meta' do
    it 'merges into a copy by top-level key, beside the loop-file keys' do
      s = sample[wav]
      c = s.with_meta(notes: 'dusty')
      d = c.with_meta({ source: s.meta[:source].merge(kind: :loop) }, tags: [:drums])
      expect(s.meta).not_to have_key(:notes)
      expect(c.meta.keys).to eq(%i[why smpl_loops source notes])
      expect(c.meta[:source]).to equal(s.meta[:source])
      expect(d.meta[:source][:kind]).to eq(:loop)
      expect(d.meta).to include(notes: 'dusty', tags: [:drums])
      expect(d.meta).to be_frozen
      expect(d.audio).to equal(s.audio)
      expect { s.with_meta(source: { sample: s }) }.to raise_error(ArgumentError, /meta\[:source\]\[:sample\] is a MB::Sound::Sample/)
      expect { s.with_meta('source' => 1) }.to raise_error(ArgumentError, /top-level metadata keys are Symbols/)
    end

    it 'stays through copies, views, and edits' do
      s = sample[audio, name: 'kick'].with_meta(source: xm)
      kept = [s.with(root: 48), s.reverse, s.trim(100...2000), s[100...2000], s.looped(0...2400), s.gain(0.5), s.transpose(3), s.stretch(1.5), s.bits(8), s.mono]
      expect(kept.map { |x| x.meta[:source] }).to all(equal(s.meta[:source]))
      expect(s.slices(4)[1].meta[:source]).to equal(s.meta[:source])
    end

    it 'prints through the sample\'s lineage, so documents keep it' do
      path = wav('doc.wav')
      s = sample[path].with_meta(source: xm).reverse
      node = MB::Sound.seq(MB::Sound::C4).n4.sampler(s)
      text = MB::Sound::GraphIO.dump(node, name: 'carried', assets: nil)
      expect(text).to include('.with_meta(source: { format: :xm, kind: :sample, id: 4, at: 10768, bytes: 9120, fields: { "finetune" => -3, ratio: 3/4r, loop: [0, 1200] } }).reverse')
    end
  end

  describe '#save' do
    it 'keeps :source in a tag, read back as the same values' do
      s = sample[audio, name: 'kick'].with_meta(source: xm, notes: 'not saved')
      expect(s.tags[:mb_sample_source]).to eq(MB::Sound::RubyValue.to_ruby(xm))
      path = tmp_path('kick.flac')
      s.save(path)
      back = sample[path]
      expect(back.meta).to eq(source: xm)
      expect(back.meta[:source][:fields][:ratio]).to eql(3/4r)
      expect(back.meta[:source]).to be_frozen
    end

    it 'carries a WAV file\'s provenance into what is saved from it' do
      s = sample[wav('origin.wav', extra: [['bext', 'x' * 10]])]
      path = tmp_path('stretched.flac')
      s.stretch(1.5).save(path)
      expect(sample[path].meta[:source]).to eq(s.meta[:source])
      expect(sample[path].meta[:source][:file]).to eq('origin.wav')
    end

    it 'saves no tag without a source, and leaves out one too large for a tag with a warning' do
      expect(sample[audio, name: 'bare'].tags).not_to have_key(:mb_sample_source)
      big = sample[audio, name: 'big'].with_meta(source: { fields: { blob: 'x' * 40_000 } })
      tags = nil
      expect { tags = big.tags }.to output(/Sample "big": its :source metadata is 39.1 KB as text, too large for a tag \(32.0 KB\); saved without it/).to_stderr
      expect(tags).not_to have_key(:mb_sample_source)
    end

    it 'runs nothing from a tag: text that is not plain values is ignored' do
      src = MB::Sound::Sample::Source
      expect(src.saved({ 'MB_SAMPLE_SOURCE' => '{ format: :xm, id: 4 }' })).to eq(format: :xm, id: 4)
      expect(src.saved({ 'mb_sample_source' => 'system("touch /nonexistent/x")' })).to be_nil
      expect(src.saved({ 'mb_sample_source' => '[1, 2]' })).to be_nil
      expect(src.saved({ 'mb_sample_source' => '{ a: ' })).to be_nil
      expect(src.saved({})).to be_nil
    end
  end
end

# Metadata in foreign formats (metadata-2, step 4; Meta::Formats): native
# tags for people, one Ruby literal for the whole Hash, read back without
# running it; native tags never override the Ruby text, and a foreign
# file's tags are description only.
require_relative '../../../../support/midi_writer'
require_relative '../../../../support/sf2_writer'

RSpec.describe(MB::Sound::Meta::Formats, :aggregate_failures) do
  let(:fmt) { described_class }
  let(:meta) do
    MB::Sound::Meta::Value[
      notes: ['a test tone', 'line two'], author: 'mb', license: 'CC0-1.0', tags: [:dark, :test],
      source: { format: :xm, id: 3, fields: { 'vol' => 1/2r } }, odd: { 7 => [nil, -0.0, :x] }
    ]
  end
  let(:tone) { Numo::SFloat.new(4800).seq.map { |i| Math.sin(i * 0.05) * 0.5 } }

  def sample = MB::Sound::Sample[tone, name: 'tone'].with_meta(meta)

  describe 'sound files' do
    %w[wav flac ogg mp3].each do |ext|
      it "round-trips a Sample's metadata through a .#{ext} file, with native tags any player shows" do
        path = tmp_path("tone.#{ext}")
        sample.save(path)
        back = MB::Sound::Sample[path]
        expect(back.meta.without(:why, :smpl_loops)).to eq(meta)
        expect(back.meta.dig(:source, :fields, 'vol')).to eql(1/2r)
        expect(back.name).to eq("tone.#{ext}") # (a file's title never names the Sample)
        info = MB::Sound::FFMPEGInput.parse_info(path)
        tags = (info.dig(:streams, 0, :tags) || {}).merge(info.dig(:format, :tags) || {}).transform_keys { |k| k.to_s.downcase }
        expect(tags.slice('title', 'artist', 'copyright')).to eq('title' => 'tone', 'artist' => 'mb', 'copyright' => 'CC0-1.0')
        expect(tags['comment']).to eq("a test tone\nline two")
      end
    end

    it 'writes LIST INFO and an mbmt chunk after a WAV\'s audio, RIFF and RF64 sizes updated' do
      path = tmp_path('t.wav')
      MB::Sound.write(path, [tone], meta: meta, meta_title: 'tone')
      riff = MB::Sound::Sample::Riff.read(path)
      expect(riff.info).to include('INAM' => 'tone', 'ICMT' => "a test tone\nline two", 'IART' => 'mb', 'ICOP' => 'CC0-1.0', 'IKEY' => 'dark; test')
      expect(riff.chunks.map(&:first)).to include('LIST', 'mbmt')
      expect(File.binread(path, 4, 4).unpack1('V')).to eq(File.size(path) - 8)
      expect(MB::Sound.read(path)[0].length).to eq(4800)

      rf = tmp_path('t_rf64.wav')
      MB::Sound::Sample::Riff.write(rf, tone, rf64: true, extra: [['junk', 'abc'.b]], pad: false)
      fmt.append_wav(rf, meta, title: 'rf')
      r = MB::Sound::Sample::Riff.read(rf)
      expect(r.container).to eq(:rf64)
      ds64 = r.chunks.find { |id, _, _| id == 'ds64' }
      expect(File.binread(rf, 8, ds64[1] + 8).unpack1('Q<')).to eq(File.size(rf) - 8)
      expect(fmt.read_wav(rf)).to eq(meta)
      expect(r.frames).to eq(4800)
    end

    it 'reads a foreign WAV\'s INFO as description, and its Ruby text alone when it has one' do
      path = tmp_path('foreign.wav')
      MB::Sound::Sample::Riff.write(path, tone, info: { 'INAM' => 'Kick 01', 'ICMT' => "Free sample\r\nUse it", 'IART' => 'Someone', 'IKEY' => 'drums, kick' })
      s = MB::Sound::Sample[path]
      expect(s.meta.to_h.slice(:title, :notes, :author, :tags)).to eq(title: 'Kick 01', notes: ['Free sample', 'Use it'], author: 'Someone', tags: %w[drums kick])
      expect(s.name).to eq('foreign.wav')
      expect(s.meta[:source][:skipped]).to eq([]) # (LIST counts as read)

      both = tmp_path('both.wav')
      MB::Sound::Sample::Riff.write(both, tone, info: { 'INAM' => 'edited elsewhere', 'IART' => 'Other' }, extra: [['mbmt', '{ author: "mb", notes: ["kept"] }'.b]])
      expect(fmt.read_wav(both)).to eq(author: 'mb', notes: ['kept'])
    end

    it 'runs nothing from a file: Ruby text that isn\'t plain values is ignored' do
      path = tmp_path('evil.wav')
      MB::Sound::Sample::Riff.write(path, tone, info: { 'INAM' => 'evil' }, extra: [['mbmt', '{ a: system("touch /tmp/mb_meta_ran") }'.b]])
      expect(fmt.read_wav(path)).to eq(title: 'evil')
      expect(File.exist?('/tmp/mb_meta_ran')).to be(false)
      expect(fmt.from_tags('MB_SOUND_META' => '`touch /tmp/mb_meta_ran`', 'title' => 'x')).to eq(title: 'x')
      expect(fmt.from_tags('mb_sound_meta' => '[1, 2]')).to eq({})
    end

    it 'still reads the :source tag files saved before (mb_sample_source)' do
      path = tmp_path('old.flac')
      MB::Sound.write(path, [tone], metadata: { mb_sample_root: 60, mb_sample_source: '{ format: :mod, id: 9 }' })
      expect(MB::Sound::Sample[path].meta[:source]).to eq(format: :mod, id: 9)
    end
  end

  describe 'MIDI files' do
    it 'round-trips metadata through meta events, and reads a foreign file\'s names, text, copyright, and markers' do
      path = tmp_path('meta.mid')
      MidiWriter.write(path, tracks: [{ name: nil, notes: [[0, 480, 48, 100], [480, 960, 52, 90]], meta: fmt.midi_events(meta, title: 'Bass') }])
      f = MB::Sound::MIDI::MIDIFile.new(path)
      expect(fmt.read_midi(f, 1)).to eq(meta)
      clip = MB::Sound.midi_clip(path)
      expect(clip.meta).to eq(meta)
      expect(clip.to_ruby).not_to include('with_meta') # (read again with the file)

      foreign = tmp_path('foreign.mid')
      MidiWriter.write(foreign, tracks: [{ name: 'Lead', notes: [[0, 480, 60, 100]], meta: [[0x02, '(c) 2001 Someone'], [0x01, 'played live'], [0x06, 'chorus', 960]] }])
      m = fmt.read_midi(MB::Sound::MIDI::MIDIFile.new(foreign))
      expect(m[:title]).to eq('Conductor')
      expect(m.license).to eq('(c) 2001 Someone')
      expect(m.notes).to eq(['played live'])
      expect(m[:markers]).to eq([[0.5, 'chorus']])
      expect(MB::Sound.midi_clip(foreign).meta.to_h).to include(title: 'Lead', notes: ['played live'])
    end
  end

  describe 'SoundFonts' do
    it 'reads a font\'s INFO as description, with where it came from' do
      path = tmp_path('font.sf2')
      SF2Writer.write(path, info: { 'INAM' => 'Spec Font', 'ICMT' => "Made for specs\nfree", 'IENG' => 'mb', 'ICOP' => 'CC0' },
                            samples: [{ name: 'sine', data: Array.new(1000) { |i| Math.sin(i * 0.1) * 0.5 }, rate: 44100, pitch: 60 }],
                            instruments: [{ name: 'Sine', zones: [{ sample_id: 0 }] }], presets: [{ name: 'Sine', program: 0, zones: [{ instrument: 0 }] }])
      m = MB::Sound::Sampler::SF2.open(path).meta
      expect(m.to_h.except(:source)).to eq(title: 'Spec Font', notes: ['Made for specs', 'free'], author: 'mb', license: 'CC0')
      expect(m.source).to include(format: :sf2, file: 'font.sf2', version: '2.4')
    end
  end

  describe 'sidecars' do
    it 'writes one meta statement beside a file and reads it back without running it' do
      path = tmp_path('loop.aiff')
      File.binwrite(path, 'not read here')
      side = fmt.write_sidecar(path, meta)
      expect(side).to eq("#{path}.meta.rb")
      text = File.read(side)
      expect(text.lines.grep_v(/\A#/).join).to start_with("meta(\n  notes: [\"a test tone\", \"line two\"],\n")
      expect(fmt.read_sidecar(path)).to eq(meta)
      expect(fmt.read_sidecar(tmp_path('none.wav'))).to be_nil
    end

    it 'merges a sidecar over what a sound or MIDI file carries' do
      path = tmp_path('k.wav')
      MB::Sound::Sample::Riff.write(path, tone, info: { 'INAM' => 'Kick' })
      fmt.write_sidecar(path, { notes: ['ours'] })
      expect(MB::Sound::Sample[path].meta.to_h).to include(title: 'Kick', notes: ['ours'])

      mid = tmp_path('m.mid')
      MidiWriter.write(mid, tracks: [{ name: 'Lead', notes: [[0, 480, 60, 100]] }])
      fmt.write_sidecar(mid, { pack: :demo })
      expect(fmt.read_midi(MB::Sound::MIDI::MIDIFile.new(mid)).pack).to eq(:demo)
    end

    it 'refuses sidecars that are links, too long, or more than plain values' do
      path = tmp_path('x.wav')
      File.write("#{path}.meta.rb", 'meta notes: [`id`]')
      expect { expect(fmt.read_sidecar(path)).to be_nil }.to output(/metadata ignored \(metadata text holds plain values only/).to_stderr
      File.write("#{path}.meta.rb", "meta notes: ['a']\nsystem('x')\n")
      expect { expect(fmt.read_sidecar(path)).to be_nil }.to output(/holds one `meta` statement/).to_stderr
      File.write("#{path}.meta.rb", "meta notes: [#{('x' * 70_000).inspect}]")
      expect { expect(fmt.read_sidecar(path)).to be_nil }.to output(/over the limit/).to_stderr
      File.delete("#{path}.meta.rb")
      target = tmp_path('elsewhere.rb')
      File.write(target, 'meta notes: ["linked"]')
      File.symlink(target, "#{path}.meta.rb")
      expect { expect(fmt.read_sidecar(path)).to be_nil }.to output(/a link/).to_stderr
    end
  end
end

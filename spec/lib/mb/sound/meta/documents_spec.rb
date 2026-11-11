# Descriptive metadata in mb-sound's Ruby documents (metadata-2, step 3):
# `meta:` keywords on the header line, `.with_meta(...)`/`.note(...)` on
# the objects (nodes, bundles, clips, Samples), set documents' `meta`
# lines, and takes' `meta:`; every one read back without running it, and
# saved again as it was.
RSpec.describe('metadata in documents', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:sessions) { [] }

  after do
    sessions.each(&:close)
    MB::Sound::Session.existing&.close
    MB::Sound.rewind
  end

  def session
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def without_stamps(text)
    text.sub(/saved: "[^"]*"/, '').sub(/mb_sound: "[^"]*"/, '')
  end

  it 'keeps a graph document\'s metadata and its nodes\' notes through load and save' do
    g = MB::Sound.stereo(220.hz.saw.note('the left').lp4(900), 221.hz.saw.with_meta(author: 'mb')).note('wide')
    text = io.dump(g, name: 'wide_saw', meta: { description: 'Two saws', meta: { license: 'CC0-1.0', links: ['https://example.com'] } })
    expect(text).to include('meta: { license: "CC0-1.0", links: ["https://example.com"] }')
    expect(text).to include('.note("the left")', '.with_meta(author: "mb")', '.note("wide")')
    loaded = io.load(text)
    expect(loaded.meta.notes).to eq(['wide'])
    expect(io.document_of(loaded).meta.license).to eq('CC0-1.0')
    again = io.dump(loaded)
    expect(without_stamps(again)).to eq(without_stamps(text))
  end

  it 'keeps a rack document\'s metadata' do
    s = session
    MB::Sound::Session.with_context(session: s) do
      rack = MB::Sound.arack(:dusty) { |sig| sig.lp4(1200).note('the dust') * MB::Sound.knob(:level, 0.5) }
      text = io.dump(rack, meta: { meta: { author: 'mb', pack: :demo } })
      expect(text).to include('rack: :arack', 'meta: { author: "mb", pack: :demo }', '.note("the dust")')
      doc = io.parse(text)
      expect(doc.header[:rack]).to eq(:arack)
      expect(doc.meta.pack).to eq(:demo)
      back = io.load(text)
      expect(back).to be_a(MB::Sound::Rack)
      expect(without_stamps(io.dump(back))).to eq(without_stamps(text))
    end
  end

  it 'keeps clips\' notes, pieces\' metadata, and the set\'s in set documents' do
    s = session
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.instance_exec do
        riff = seq(MB::Sound::A2, MB::Sound::C3, MB::Sound::E3).n8.loop.named(:riff).note('the old riff')
        track(:bass) { |clip| clip.synth(voices: 1) { |v| v.hz.saw.note('raw') * v.amp_env(0.003, 0.1, 0.5, 0.05) } * 0.3 }
        scene :one, bass: riff
        meta :bass, notes: ['doubled live'], author: 'mb'
        meta source: { format: :acd, file: 'old.acd' }
      end
    end
    text = io.dump(s.arrangement, name: 'noted', meta: { meta: { pack: :demo } })
    expect(text).to include('meta: { pack: :demo }', '.named(:riff).note("the old riff")', 'v.hz.saw.note("raw")')
    expect(text).to include('meta :bass, notes: ["doubled live"], author: "mb"', 'meta source: { format: :acd, file: "old.acd" }')
    t = session
    doc = io.load(text, session: t)
    expect(doc.meta.pack).to eq(:demo)
    expect(t.metadata[:bass].notes).to eq(['doubled live'])
    expect(without_stamps(io.dump(t.arrangement, name: 'noted', meta: { meta: { pack: :demo } }))).to eq(without_stamps(text))
  end

  it 'keeps a Sample\'s notes through its lineage' do
    path = tmp_path('tone.wav')
    MB::Sound.write(path, Numo::SFloat.new(4800).seq.map { |i| Math.sin(i * 0.05) * 0.5 }, sample_rate: 48000)
    s = MB::Sound::Sample[path].note('a test tone').with_meta(author: 'mb')
    text = io.dump(MB::Sound.seq(MB::Sound::C4.n4).sampler(s), name: 'tone')
    expect(text).to include('.note("a test tone").with_meta(author: "mb")')
  end
end

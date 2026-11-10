# Metadata in saved documents (source-meta-1; graph_io.md, "Metadata"): set
# documents end with the `meta` lines of the set and its names, load them
# back, and save the same text again; `ruby set` prints that document.
require_relative '../../../support/meta_song'

RSpec.describe('metadata in set documents', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:sessions) { [] }
  let(:long) { { format: :acd, kind: :bus, id: 2, fields: { 'plug-in' => ['Reverb', 'Big Hall', 4096], 7 => 1/3r, list: (1..40).to_a, flag: nil, deep: { a: [true, -1.5, :"two words"] } } } }

  after { sessions.each(&:close) }

  def session
    MB::Sound::Session.new(
      master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def within(s, &block)
    MB::Sound::Session.with_context(session: s) { MB::Sound.instance_exec(&block) }
  end

  def render(s, buffers)
    Array.new(buffers) { s.process_buffer.map(&:dup) }.transpose.map { |c| SpecBuffers.join(c) }
  end

  def body(text)
    text.lines.drop_while { |l| !l.start_with?('graph ') }.drop(1).join
  end

  # The spec song with its metadata (and a long entry), played to its end.
  def carried_set
    s = session
    long_meta = long
    MB::Sound::Session.with_context(session: s) { MB::Sound::MetaSong.song(true) }
    render(s, 240)
    within(s) { meta :fx1, source: long_meta }
    s
  end

  it 'saves the set\'s metadata as `meta` lines at the end, the set\'s own first' do
    s = carried_set
    text = io.dump(s.arrangement, name: 'carried')
    expect(text).to include("graph #{io::FORMAT}, name: \"carried\", kind: :set")
    tail = text[text.index("\n# Metadata:")..]
    expect(text.lines.grep(/^(track|bus|scene)\b/).map { |l| text.index(l) }.max).to be < text.index("\n# Metadata:")
    expect(tail).to eq(<<~RUBY)

      # Metadata: what the set and its pieces carry from where they came from (no effect on the sound; help :meta)
      meta source: { format: :acd, file: "project.acd", bytes: 1234567, version: "7.0", unread: 0.19 }
      meta(:fx1,
        source: {
          format: :acd, kind: :bus, id: 2,
          fields: {
            "plug-in" => ["Reverb", "Big Hall", 4096], 7 => 1/3r,
            list: [
              1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
              31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
            ],
            flag: nil, deep: { a: [true, -1.5, :"two words"] },
          },
        })
      meta :pad, source: { kind: :track, at: 99 }
      meta :ghost, source: { kind: :track, unread: 12 }
      meta(:a3,
        source: {
          format: :acd, kind: :track, at: 74560, bytes: 5678, name: "the track's own name", fields: { color: 3, height: 80 },
        })
    RUBY
    # (a node's own metadata prints inside its patch)
    expect(text).to include('.with_meta(source: { format: :acd, kind: :plugin, id: 1 })')
  end

  it 'loads it back into the Session, saves the same text again, and plays the same' do
    s = carried_set
    text = io.dump(s.arrangement, name: 'carried')
    s2 = session
    io.load(text, session: s2)
    expect(s2.metadata.to_h).to eq(s.metadata.to_h)
    expect(s2.metadata[nil]).to eq(s.metadata[nil])
    expect(s2.metadata[:fx1][:source][:fields][7]).to eql(1/3r)
    expect(s2.metadata.names).to eq(s.metadata.names)
    expect(body(io.dump(s2.arrangement, name: 'carried'))).to eq(body(text))

    # the same set saved without its metadata: the same document but
    # those lines, and the same sound from either
    s3 = session
    io.load(text, session: s3)
    within(s3) { [nil, *s3.metadata.names].each { |n| meta n, nil } }
    plain = io.dump(s3.arrangement, name: 'carried')
    expect(plain).not_to include('# Metadata')
    expect(body(text)).to start_with(body(plain))
    mixes = [text, plain].map do |doc|
      x = session
      io.load(doc, session: x)
      within(x) { go :one, on: :now }
      render(x, 120)
    end
    expect(mixes[0][0].abs.max).to be > 0.05
    expect(mixes[0].map(&:to_binary) == mixes[1].map(&:to_binary)).to be(true)
  end

  it 'prints nothing for a set without metadata, and loads documents written before metadata' do
    s = session
    MB::Sound::Session.with_context(session: s) { MB::Sound::MetaSong.song(false) }
    text = io.dump(s.arrangement, name: 'plain')
    expect(text).not_to include('meta')
    s2 = session
    io.load(text, session: s2)
    expect(s2.metadata).to be_empty
  end

  it 'takes only plain values from a document, and no block' do
    head = "graph #{io::FORMAT}, name: \"x\", kind: :set\n\nbpm 120\n"
    s = session
    io.load("#{head}meta :a3, source: { at: 16, list: [1, nil, \"x\"] }\nmeta notes: \"n\"\n", session: s)
    expect(s.metadata[:a3]).to eq(source: { at: 16, list: [1, nil, 'x'] })
    expect(s.metadata[nil]).to eq(notes: 'n')
    expect { io.load("#{head}meta :a3, source: { osc: 440.hz }\n", session: session) }.to raise_error(io::LoadError, /meta raised ArgumentError: meta\[:source\]\[:osc\] is a/)
    expect { io.load("#{head}meta(:a3) { 1 }\n", session: session) }.to raise_error(io::LoadError, /meta takes no block/)
    expect { io.load("#{head}meta :a3, source: system(\"true\")\n", session: session) }.to raise_error(io::LoadError)
  end

  it 'prints the set document for `ruby set`' do
    s = carried_set
    out = StringIO.new
    $stdout = out
    begin
      within(s) { ruby set }
    ensure
      $stdout = STDOUT
    end
    expect(out.string).to start_with('# mb-sound set document')
    expect(out.string).to include('track(:a3, ')
    expect(out.string).to include('meta :pad, source: { kind: :track, at: 99 }')
    expect(body(out.string)).to eq(body(io.dump(s.arrangement)))
  end
end

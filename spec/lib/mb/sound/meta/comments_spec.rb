# Inline comments in graph and rack documents as metadata (metadata-2,
# step 5; GraphIO::Comments): Prism attaches each comment to a node, the
# loader gives it to the object that node builds (meta[:notes], argument
# comments meta[:arg_notes]), and the writer prints them back as comments.
RSpec.describe(MB::Sound::GraphIO::Comments, :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }
  let(:head) { "graph #{MB::Sound::GraphIO::FORMAT}, name: \"c\", kind: :graph\n\n" }
  let(:body) do
    <<~RUBY
      # the pad
      # two lines
      pad = 220.hz.saw # bright
        .lp4(
          800, # the cutoff
          resonance: 0.3 # not too much
        ) # darker
      # out
      pad.softclip + 330.hz.sine
    RUBY
  end

  def without_stamps(text) = text.sub(/saved: "[^"]*", mb_sound: "[^"]*"/, '')

  def render(g)
    MB::Sound.rewind
    SpecBuffers.join(Array.new(6) { g.sample(800).dup }).to_binary
  end

  after { MB::Sound.rewind }

  it 'gives leading, trailing, and argument comments to the objects they describe' do
    g = io.load(head + body)
    expect(g.meta.notes).to eq(['out'])
    lp = g.graph.find { |n| n.is_a?(MB::Sound::GraphNode::FourPole) }
    expect(lp.meta.notes).to eq(['the pad', 'two lines', 'darker'])
    expect(lp.meta[:arg_notes]).to eq(0 => 'the cutoff', resonance: 'not too much')
    saw = g.graph.find { |n| n.is_a?(MB::Sound::Tone) && n.frequency == 220 }
    expect(saw.meta.notes).to eq(['bright'])
    expect(g.to_ruby).not_to include('.note(') # (given quietly: printed as comments)
  end

  it 'prints them back as comments, and the saved text loads and saves the same' do
    g = io.load(head + body)
    text = io.dump(g)
    expect(text).to include("# the pad\n# two lines\n# darker\n", "220.hz.saw # bright\n", "    800, # the cutoff\n", "    resonance: 0.3 # not too much\n", "# out\n")
    again = io.dump(io.load(text))
    expect(without_stamps(again)).to eq(without_stamps(text))
  end

  it 'changes no sample' do
    plain = body.lines.map { |l| l.sub(/\s*#.*/, '') }.reject { |l| l.strip.empty? }.join
    expect(render(io.load(head + body))).to eq(render(io.load(head + plain)))
  end

  it 'prints a note where no comment can go as .note, and keeps it from then on' do
    src = head + "220.hz.saw.lp4(110.hz.lfo.at(300..900), # the sweep\n  resonance: 0.2)\n"
    g = io.load(src)
    lfo = g.graph.find { |n| n.respond_to?(:meta) && n.meta.notes == ['the sweep'] }
    expect(lfo).not_to be_nil
    text = io.dump(g)
    expect(text).to include('110.hz.lfo.at(300..900).note("the sweep")')
    expect(without_stamps(io.dump(io.load(text)))).to eq(without_stamps(text))
  end

  it 'keeps writer comments, set documents\' comments, and comments on values out of the notes' do
    g = io.load(head + "# WARNING(graph-io): something the writer said\n220.hz.saw.at(0.5 # half\n)\n")
    expect(g.meta.notes).to eq([])
    expect(g.meta[:arg_notes]).to eq(0 => 'half')

    s = MB::Sound::Session.new(realtime: false)
    begin
      doc = io.load("graph #{io::FORMAT}, name: \"s\", kind: :set\n\nbpm 120\n# the pad\ntrack :pad, 220.hz.triangle # soft\n", session: s)
      expect(doc.session.arrangement.tracks[:pad]).not_to be_nil
      expect(s.metadata[:pad]).to eq({})
    ensure
      s.close
    end
  end

  it 'reads comments in rack documents\' bodies' do
    s = MB::Sound::Session.new(realtime: false)
    MB::Sound::Session.with_context(session: s) do
      text = io.dump(MB::Sound.arack(:dusty) { |sig| sig.lp4(1200) * MB::Sound.knob(:level, 0.5) })
      text = text.sub(/^(sig\.lp4.*)$/) { "# warm\n#{$1} # dusty" }
      expect(text).to include("# warm\nsig.lp4(1200)")
      rack = io.load(text)
      out = rack.call(220.hz.saw)
      expect(out.meta.notes).to eq(%w[warm dusty])
    end
  ensure
    s.close
  end

  it 'turns hostile comments into quoted notes and runs nothing' do
    g = io.load(head + "220.hz.saw # system(\"touch /tmp/mb_comment_ran\") \\e[2J\n")
    expect(g.meta.notes).to eq(['system("touch /tmp/mb_comment_ran") \\e[2J'])
    expect(File.exist?('/tmp/mb_comment_ran')).to be(false)
    expect(MB::Sound::Meta.notes_text(g.meta.notes)).to start_with('"system(\\"touch')
  end

  it 'collects nothing for a document without comments of its own' do
    text = io.dump(220.hz.saw.lp4(800))
    result = Prism.parse(text)
    body = result.value.statements.body.drop(1)
    expect(described_class.collect(result, body)).to be_nil
  end
end

# Argument errors of the MIDI transforms (notes-fix-1, 2026-10-31; the
# maintainer: "This needs a 'did you mean' help" after `clip.echo()` said
# "wrong number of arguments (given 0, expected 1..2)" and
# `clip.echo(3, transpose: 5)` "unknown keyword: :transpose"): every
# transform (MIDI::Stream::TRANSFORMS, also through Clip, Notes, and
# unattached chains) names itself, says what it takes, and shows a working
# call (MIDI::Stream::EXAMPLES, each run here).
RSpec.describe('MIDI transform argument errors', :aggregate_failures) do
  let(:clip) { MB::Sound.seq(MB::Sound::C2, MB::Sound::A2, MB::Sound::C3, MB::Sound::G1).n8.loop }

  after { MB::Sound.rewind }

  # Captures one call: [name, args, kwargs, block].
  class TransformCallRecorder < BasicObject
    def method_missing(name, *args, **kwargs, &block)
      [name, args, kwargs, block]
    end

    def respond_to_missing?(*)
      true
    end
  end

  # The call of +name+'s example, as [args, kwargs, block].
  def example_call(name)
    ctx = MB::Sound.module_eval('binding', __FILE__, __LINE__)
    ctx.local_variable_set(:rec, TransformCallRecorder.new)
    ctx.local_variable_set(:feel, :feel)
    called, *call = ctx.eval("rec.#{MB::Sound::MIDI::Stream::EXAMPLES.fetch(name)}")
    expect(called).to eq(name)
    call
  end

  # A one-line console message (ErrorFormat.summary) of what +block+ raises.
  def summary_of(&block)
    block.call
    nil
  rescue ArgumentError => e
    MB::Sound::ErrorFormat.summary(e)
  end

  it 'has a working example for every transform' do
    names = MB::Sound::MIDI::Stream::TRANSFORMS
    expect(MB::Sound::MIDI::Stream::EXAMPLES.keys).to match_array(names)
    (names - [:rotate]).each do |name|
      args, kwargs, block = example_call(name)
      args = args.map { |a| a.equal?(:feel) ? clip : a }
      s = clip.stream.public_send(name, *args, **kwargs, &block)
      expect(s).to be_a(MB::Sound::MIDI::Stream), name.to_s
      r = s.reader
      expect { 20.times { |i| r.events(i / 10r, (i + 1) / 10r) } }.not_to raise_error, name.to_s
    end
  end

  it 'names the transform, what it takes, and an example for unknown keywords and wrong arity' do
    (MB::Sound::MIDI::Stream::TRANSFORMS - [:rotate]).each do |name|
      args, kwargs, block = example_call(name)
      args = args.map { |a| a.equal?(:feel) ? clip : a }
      types = MB::Sound::MIDI::Stream.instance_method(name).super_method.parameters.map(&:first)
      unless types.include?(:rest) && (types & %i[key keyreq keyrest]).empty? # (keys(*notes) takes a keyword as a note: its own error)
        bogus = summary_of { clip.stream.public_send(name, *args, **kwargs, zzz_bogus: 1, &block) }
        expect(bogus).to match(/\AArgumentError: #{name}: (unknown keywords?: :zzz_bogus|wrong number of arguments).*; e\.g\. riff\.#{Regexp.escape(name.to_s)}/), "#{name}: #{bogus.inspect}"
        expect(bogus).not_to include("\n")
      end

      next if types.include?(:rest)
      many = summary_of { clip.stream.public_send(name, *args, *([1] * 8), **kwargs, &block) }
      expect(many).to match(/\AArgumentError: #{name}: wrong number of arguments \(given \d+, expected [^)]+\); #{name}\(.*\); e\.g\. riff\.#{Regexp.escape(name.to_s)}/), "#{name}: #{many.inspect}"
    end
  end

  it "answers the maintainer's echo lines on clips, Notes, and unattached chains" do
    # A bare echo() echoes eighths, 3 times (as arp() and strum() have defaults)
    expect(clip.echo.source).to have_attributes(delay: 1.n8, count: 3)

    msg = summary_of { clip.echo(3, transpose: 5) }
    expect(msg).to eq('ArgumentError: echo: unknown keyword: :transpose; e.g. riff.echo(3.n16, 3, pitch: 7.st, velocity: 0.7) (did you mean pitch:?)')
    expect(summary_of { clip.echo(1.n8, 3, velocty: 0.5) }).to end_with('(did you mean velocity:?)')
    expect(summary_of { clip.echo(1.n8, 3, zzz: 1) }).to match(/echo: unknown keyword: :zzz \(echo takes pitch:, velocity:, gate:, dry:, scale:, root:.*\); e\.g\. /)
    expect(summary_of { clip.echo(1, 2, 3) }).to start_with('ArgumentError: echo: wrong number of arguments (given 3, expected 0..2); echo(delay = 1.n8, count = 3, **options, &block); e.g. riff.echo(')
    # (keywords passed on to the transform's base classes: Arp to Scheduled)
    expect(summary_of { clip.arp(:up, 16, octavs: 2) }).to end_with('(did you mean octaves:?)')

    notes = MB::Sound::Notes.new(clip.stream)
    expect(summary_of { notes.echo(1.n8, 3, transpose: 5) }).to start_with('ArgumentError: echo: unknown keyword: :transpose;')
    expect(summary_of { MB::Sound.echo(1, 2, 3).apply(clip) }).to start_with('ArgumentError: echo: wrong number of arguments')
  end

  it 'leaves argument errors from deeper inside alone' do
    expect { clip.echo(-1) }.to raise_error(ArgumentError, /\AAn echo delay can't be negative/)
    expect { clip.stream.through }.to raise_error(ArgumentError, /\APass a transform chain/)
  end
end

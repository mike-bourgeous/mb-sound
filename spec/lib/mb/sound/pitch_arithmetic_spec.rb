# Pitches taken as frequencies in signal arithmetic (ux-notes-2; the
# maintainer's note 14: `it.hz + 150` added 150 to the sine a Pitch plays
# as a signal, where `it.freq + 150` was meant; his "Warn once per site"
# and "it.hz + 150.hz should live_error with the did-you-mean as well").
# GraphNode::ArithmeticMethods.check_pitch, swept over the operators and
# the operand kinds: sums stay sums (the operators rule), with a warning for
# a Pitch and a number and an error (a warning in live mode) for two
# Pitches or a frequency node and a Pitch.
RSpec.describe('Pitch arithmetic checks', :aggregate_failures) do
  let(:notes) { MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::C4).stream) }

  after { MB::Sound.live = false }

  # The operands, by kind (lambdas: each makes fresh nodes).
  def operands
    {
      voice_pitch: -> { notes.hz },          # it.hz
      pitch: -> { 440.hz },
      note: -> { MB::Sound::C4 },
      number: -> { 150 },
      constant: -> { 150.constant },
      frequency: -> { notes.freq },          # it.freq, a frequency node
      tone: -> { 220.hz.saw },
      node: -> { MB::Sound.noise },
    }
  end

  PITCH_KINDS = %i[voice_pitch pitch note].freeze
  NUMBER_KINDS = %i[number constant].freeze

  # What `left op right` does: :warn (a Pitch and a number added or
  # subtracted), :error (two Pitches, or a frequency node and a Pitch), or
  # :silent.
  def expected(op, left, right)
    return :silent unless %i[+ -].include?(op)
    l_pitch = PITCH_KINDS.include?(left)
    r_pitch = PITCH_KINDS.include?(right)
    return :error if l_pitch && r_pitch
    return :error if left == :frequency && r_pitch
    return :warn if l_pitch && NUMBER_KINDS.include?(right)
    return :warn if NUMBER_KINDS.include?(left) && r_pitch
    :silent
  end

  # Runs `left op right` (a number on the left goes through coerce) on its
  # own line each time (the warning is once per calling line), returning
  # [result or the error, stderr].
  def run(op, left, right)
    b = operand_binding(operands.fetch(left).call, operands.fetch(right).call)
    result = nil
    err = capture_stderr { result = begin; eval("l #{op} r", b, "(op #{@site = (@site || 0) + 1})", 1); rescue ArgumentError => e; e; end }
    [result, err]
  end

  def operand_binding(l, r) = binding

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it 'warns, raises, or stays quiet for every operator and pair of operand kinds' do
    kinds = operands.keys
    seen = Hash.new(0)
    %i[+ - * /].each do |op|
      kinds.each do |left|
        kinds.each do |right|
          next if left == :number && right == :number
          next if %i[* /].include?(op) && left == :number && !operands[right].call.respond_to?(:coerce) # (plain Ruby)
          want = expected(op, left, right)
          result, err = run(op, left, right)
          what = "#{left} #{op} #{right}"
          seen[want] += 1
          case want
          when :error
            expect(result).to be_a(ArgumentError), what
            expect(result.message).to match(/freq [+-] \S+ \(a node of Hz|write \d+\.hz/), what
            expect(err).to eq(''), what
          when :warn
            expect(result).to be_a(MB::Sound::GraphNode), what
            expect(err).to match(/warning: .* the full-scale sine a Pitch plays as a signal/), what
          else
            expect(result).not_to be_a(Exception), what
            expect(err).to eq(''), what
          end
        end
      end
    end
    expect(seen.keys).to contain_exactly(:warn, :error, :silent)
  end

  it 'names the frequency form the maintainer meant, and semitones' do
    _, err = run(:+, :voice_pitch, :number)
    expect(err).to include('it.hz + 150 adds 150 to the full-scale sine', 'for 150 Hz above it write it.freq + 150', 'cutoff:', '(it.freq + 150).tone')
    _, err = run(:+, :pitch, :number)
    expect(err).to include('440.hz + 150', 'for 590 Hz write 590.hz')
    l = MB::Sound::C4
    err = capture_stderr { l + 7 }
    expect(err).to include('C4 + 7', 'C4.transpose(7) for semitones')

    e, = run(:+, :voice_pitch, :pitch)
    expect(e.message).to include('it.hz + 440.hz mixes two full-scale sines', 'it.freq + 440', 'it.hz.sine + 440.hz.sine')
    # (`it.freq + 150.hz` adds a 150 Hz sine to the frequency, and nodes
    # have no .hz, so `it.freq + 150` is the form that means it)
    e = (notes.freq + 150.hz rescue $!)
    expect(e.message).to include('it.freq + 150.hz adds a full-scale 150 Hz sine to the frequency', 'write it.freq + 150')
    expect(notes.freq + 150).to be_a(MB::Sound::GraphNode::Mixer) # (the form suggested: quiet)
    expect { notes.freq + 150 }.not_to output.to_stderr
  end

  it 'warns once per calling line' do
    n = notes
    err = capture_stderr { 2.times { n.hz + 150 } }
    expect(err.scan('warning:').length).to eq(1)
    err = capture_stderr { n.hz + 150 }
    expect(err.scan('warning:').length).to eq(1) # (another line)
  end

  it 'warns and sums in live mode' do
    MB::Sound.live = true
    r = nil
    expect { r = notes.hz + 150.hz }.to output(/ArgumentError: it.hz \+ 150.hz mixes two full-scale sines.*\(live mode: ignored\)/).to_stderr
    expect(r).to be_a(MB::Sound::GraphNode::Mixer)
  end
end

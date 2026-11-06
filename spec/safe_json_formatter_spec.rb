require_relative 'support/safe_json_formatter'

# The batch-10 suite lost a process's report to one ASCII-8BIT string with a
# byte over 0x7F (see spec/support/safe_json_formatter.rb).
RSpec.describe(SafeJsonFormatter) do
  it 'writes binary and invalid strings as valid UTF-8, nested too, and keeps the rest' do
    bad = "a \xE2\x86\x90 arrow".b
    broken = "half \xE2\x86".dup.force_encoding(Encoding::UTF_8)
    out = described_class.scrub({ messages: [bad, broken], examples: [{ description: 'fine ←', run_time: 0.5 }] })
    expect(out[:messages]).to eq(['a ← arrow', "half �"])
    expect(out[:examples]).to eq([{ description: 'fine ←', run_time: 0.5 }])
    expect { out.to_json }.not_to raise_error
    # (the batch-10 crash: a lone byte over 0x7F in a binary String)
    expect { { m: "x \x90".b }.to_json }.to raise_error { |e| expect(e).to be_a(JSON::GeneratorError).or be_a(Encoding::UndefinedConversionError) }
    expect(described_class.scrub({ m: "x \x90".b }).to_json).to eq(%q({"m":"x �"}).sub('�', "�"))
  end

  it 'writes the report a plain JSON formatter would, through close' do
    io = StringIO.new
    f = described_class.new(io)
    f.output_hash[:messages] = ["x \x90".b]
    f.close(nil)
    expect(JSON.parse(io.string)['messages']).to eq(["x �"])
  end

  # fix-batch-1106: a recurrence names its source (the report's
  # "scrubbed" list, printed by rake spec:parallel)
  it 'lists where each string it scrubbed was, its encoding, and its first bytes, and converts text encodings' do
    found = []
    out = described_class.scrub({ examples: [{ description: 'ok', pending_message: "skip: \x90 left".b }],
                                  messages: ['plain'.b, "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)] }, found)
    expect(found).to eq([{ path: 'examples/0/pending_message', encoding: 'ASCII-8BIT', start: '"skip: \\x90 left"' }])
    expect(out[:messages]).to eq(['plain', 'café'])

    io = StringIO.new
    f = described_class.new(io)
    f.output_hash[:messages] = ['fine', "x \x90".b]
    f.close(nil)
    expect(JSON.parse(io.string)['scrubbed']).to eq([{ 'path' => 'messages/1', 'encoding' => 'ASCII-8BIT', 'start' => '"x \\x90"' }])
  end
end

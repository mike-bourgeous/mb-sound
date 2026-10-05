require 'shellwords'

RSpec.describe('bin/ab_listen.rb') do
  def run(*args)
    text = `OUTPUT_TYPE=null bin/ab_listen.rb #{args.shelljoin} 2>&1 < /dev/null`
    expect($?).to be_success, text
    text
  end

  # Writes a short stereo file of a sine at +level+.
  def tone(name, level, seconds: 0.1)
    path = tmp_path(name)
    data = 440.hz.at(level).sample((seconds * 48000).round)
    MB::Sound.write(path, [data, data], sample_rate: 48000)
    path
  end

  let(:dir) { File.dirname(tmp_path('x')) }

  it 'pairs NAME_before with NAME_after or NAME, ignoring other files' do
    tone('one_before.flac', 0.5)
    tone('one_after.flac', 0.25)
    tone('two_before.flac', 0.5)
    tone('two.wav', 0.5)
    tone('three_before.flac', 0.5) # no partner
    File.write(File.join(dir, 'two_before.txt'), 'log')

    text = run('--list', dir)
    expect(text.lines.grep(/^\S/).map(&:strip)).to eq(['one', 'two'])
    expect(text).to include('one_before.flac', 'one_after.flac', 'two_before.flac', 'two.wav')
    expect(text).not_to include('three', '.txt')

    expect(run('--list', '-F', 'tw', dir).lines.grep(/^\S/).map(&:strip)).to eq(['two'])
  end

  it 'skips non-audio files named directly (e.g. by a shell glob)' do
    tone('one_before.flac', 0.5)
    tone('one_after.flac', 0.25)
    File.write(File.join(dir, 'logs_one_before.txt'), 'log')
    File.write(File.join(dir, 'logs_one_after.txt'), 'log')

    text = run('--list', *Dir[File.join(dir, '*')].sort)
    expect(text.lines.grep(/^\S/).map(&:strip)).to eq(['Skipping 2 non-audio files (not flac/wav/ogg/opus/mp3/m4a/aac/aif/aiff/caf): logs_one_after.txt, logs_one_before.txt', 'one'])
    expect(text).not_to include('A: ' + File.join(dir, 'logs'))
  end

  it 'skips pairs whose files cannot be read' do
    File.write(tmp_path('bad_before.flac'), 'not a flac')
    tone('bad_after.flac', 0.5)
    tone('good_before.flac', 0.5, seconds: 0.2)
    tone('good_after.flac', 0.5, seconds: 0.2)

    text = run('--auto', '0.1', dir)
    expect(text).to include('Skipping bad: could not read bad_before.flac', '[1/1] good')
  end

  it 'asks for a folder when run without arguments' do
    text = `OUTPUT_TYPE=null bin/ab_listen.rb 2>&1 < /dev/null`
    expect($?).not_to be_success
    expect(text).to include('pass a folder of before/after renders')
  end

  it 'compares two files that do not pair by name' do
    a = tone('old.flac', 0.5)
    b = tone('new.flac', 0.5)
    expect(run('--list', a, b)).to include('old.flac vs new.flac', "A: #{a}", "B: #{b}")
  end

  it 'plays each pair once with --auto, switching A/B and showing levels and README notes' do
    tone('one_before.flac', 0.5, seconds: 0.3)
    tone('one_after.flac', 0.25, seconds: 0.2)
    File.write(File.join(dir, 'README.md'), "# Set\n\n- **one:** quieter after\n- other: unrelated\n")

    text = run('--auto', '0.1', dir)
    expect(text).to include('[1/1] one', 'peak -6.0 dB', '(-6.0 dB rms)', 'quieter after')
    expect(text).not_to include('unrelated')
    expect(text).to match(/A \(before\) +0\.00 \/ 0\.30 s/)
    expect(text).to match(/B \(after\) +0\.10 \/ 0\.30 s/)
    expect(text).to match(/A \(before\) +0\.20 \/ 0\.30 s/)
  end
end

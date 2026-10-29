RSpec.describe(MB::Term::Themes, :aggregate_failures) do
  let(:themes) { described_class }

  around do |example|
    saved = themes.all.dup
    current = themes.instance_variable_get(:@current)
    dir = themes.instance_variable_get(:@dir)
    example.run
  ensure
    themes.all.replace(saved)
    themes.instance_variable_set(:@current, current)
    themes.dir = dir
  end

  it 'defines themes in Ruby, based on others, and reads colors by role' do
    themes.define(:default, based_on: :default) do
      role :text, 250
      role :title, '#102030', bold: true
      glyphs(:ascii) { play '>' }
    end
    themes.define(:mine) { role :text, :bright_red }
    themes.use(:mine)
    expect(themes.rgb(:text)).to eq(9)
    expect(themes.rgb(:title)).to eq([16, 32, 48])
    expect(themes.bold?(:title)).to eq(true)
    expect(themes.glyphs(:ascii)[:play]).to eq('>')
    expect { themes.rgb(:nope) }.to raise_error(ArgumentError, /Unknown UI color role :nope/)
  end

  it 'loads theme files as data (never eval), with did-you-mean errors' do
    themes.define(:default, based_on: :default) { role :text, 250 }
    themes.dir = File.dirname(tmp_path('x'))
    File.write(tmp_path('file_theme.rb'), "theme :file_theme do\n  role :text, '#ffffff'\nend\n")
    expect(themes.use(:file_theme).roles[:text][0]).to eq([255, 255, 255])
    File.write(tmp_path('bad_theme.rb'), "theme :bad_theme do\n  rol :text, 1\nend\n")
    expect { themes.named(:bad_theme) }.to raise_error(MB::Term::DataFile::LoadError, /bad_theme\.rb:2: `rol` isn't allowed here \(did you mean `role`\?\)/)
    File.write(tmp_path('evil_theme.rb'), "theme :evil_theme do\n  system 'true'\nend\n")
    expect { themes.named(:evil_theme) }.to raise_error(MB::Term::DataFile::LoadError, /evil_theme\.rb:2: `system` isn't allowed here/)
  end
end

RSpec.describe(MB::Term::DataFile, :aggregate_failures) do
  it 'parses calls from a closed table into Calls with literal values' do
    calls = described_class.parse("box :a, 1, w: 2.5 do\n  item 'x', [1, 2], 1..3\nend\n", 'f.rb', calls: { nil => %i[box], box: %i[item] })
    expect(calls.map(&:name)).to eq([:box])
    expect(calls[0].args).to eq([:a, 1])
    expect(calls[0].opts).to eq(w: 2.5)
    expect(calls[0].children[0].args).to eq(['x', [1, 2], 1..3])
    expect(calls[0].children[0].line).to eq(2)
  end

  it 'refuses anything but plain data' do
    t = { nil => %i[box] }
    expect { described_class.parse('`ls`', 'f.rb', calls: t) }.to raise_error(described_class::LoadError, /f\.rb:1/)
    expect { described_class.parse('box File.read("x")', 'f.rb', calls: t) }.to raise_error(described_class::LoadError, /f\.rb:1/)
    expect { described_class.parse('bax 1', 'f.rb', calls: t) }.to raise_error(described_class::LoadError, /did you mean `box`/)
    expect { described_class.parse('box X', 'f.rb', calls: t) }.to raise_error(described_class::LoadError, /f\.rb:1/)
    expect(described_class.parse('box X', 'f.rb', calls: t, constants: { 'X' => 7 })[0].args).to eq([7])
  end
end

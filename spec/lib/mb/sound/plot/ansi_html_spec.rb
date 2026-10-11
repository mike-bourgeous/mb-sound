RSpec.describe(MB::Sound::Plot::AnsiHtml) do
  it 'converts truecolor, 256-color, 16-color, bold, and reverse codes' do
    html = described_class.convert("\e[1;38;2;1;2;3mA\e[0m<\e[38;5;196mB\e[0m\e[92mC\e[7;38;2;255;0;0mD\e[0m")
    expect(html).to eq(
      '<span style="color:#010203;font-weight:bold">A</span>&lt;<span style="color:#ff0000">B</span>' \
      '<span style="color:#23d18b">C</span><span style="color:#141413;background:#ff0000">D</span>'
    )
  end

  it 'wraps non-ASCII cells and collects classes' do
    classes = {}
    html = described_class.convert("\e[38;2;1;2;3m⣿x\e[0m", cells: true, classes: classes)
    expect(html).to eq('<span class="a0"><i>⣿</i>x</span>')
    expect(described_class.stylesheet(classes, scope: '.t')).to eq('.t .a0{color:#010203}')
  end

  it 'makes a page' do
    expect(described_class.page("\e[31mx\e[0m", title: 'a<b')).to include('<title>a&lt;b</title>', '<pre><span style="color:#cd3131">x</span></pre>')
  end
end

RSpec.describe(MB::Sound::Plot::Terminal) do
  it 'detects color depth from the environment' do
    expect(described_class.color_mode({ 'COLORTERM' => 'truecolor' })).to eq(:truecolor)
    expect(described_class.color_mode({ 'TERM' => 'xterm-256color' })).to eq(:ansi256)
    expect(described_class.color_mode({ 'TERM' => 'xterm' })).to eq(:ansi16)
    expect(described_class.color_mode({ 'COLORTERM' => 'truecolor', 'NO_COLOR' => '' })).to eq(:none)
    expect(described_class.color_mode({ 'TERM' => 'dumb' })).to eq(:none)
    expect(described_class.color_mode({ 'PLOT_COLOR' => '256', 'NO_COLOR' => '1' })).to eq(:ansi256)
    expect(described_class.color_mode({ 'TERM_PROGRAM' => 'iTerm.app' })).to eq(:truecolor)
  end

  it 'detects inline image protocols' do
    expect(described_class.image_protocol({ 'TERM_PROGRAM' => 'iTerm.app' })).to eq(:iterm)
    expect(described_class.image_protocol({ 'KITTY_WINDOW_ID' => '1' })).to eq(:kitty)
    expect(described_class.image_protocol({ 'KONSOLE_VERSION' => '230801' })).to eq(:sixel)
    expect(described_class.image_protocol({ 'KONSOLE_VERSION' => '210800' })).to be_nil
    expect(described_class.image_protocol({ 'TERM' => 'xterm-256color' })).to be_nil
    expect(described_class.image_protocol({ 'PLOT_IMAGES' => 'sixel' })).to eq(:sixel)
    expect(described_class.images_by_default?({ 'TERM_PROGRAM' => 'iTerm.app' })).to eq(false)
    expect(described_class.images_by_default?({ 'TERM_PROGRAM' => 'iTerm.app', 'PLOT_IMAGES' => '1' })).to eq(true)
  end

  it 'picks a light theme from COLORFGBG' do
    expect(described_class.theme({ 'COLORFGBG' => '0;15' })).to eq(:light)
    expect(described_class.theme({ 'COLORFGBG' => '15;0' })).to eq(:dark)
    expect(described_class.theme({ 'PLOT_THEME' => 'light' })).to eq(:light)
  end

  describe '.image_escape' do
    let(:image) { MB::Sound::Plot::Image.render(MB::Sound::Plot.chart { line [1, 2] }.figure, width: 64, height: 48) }

    it 'writes iTerm2 and kitty escapes, chunked for kitty' do
      iterm = described_class.image_escape(image, :iterm, env: {})
      expect(iterm).to match(/\A\e\]1337;File=inline=1;size=\d+;preserveAspectRatio=1:[A-Za-z0-9+\/=]+\a\z/)

      kitty = described_class.image_escape(image, :kitty, columns: 40, env: {})
      expect(kitty).to start_with("\e_Ga=T,f=100,q=2,c=40,m=")
      expect(kitty.scan("\e\\").length).to eq(kitty.scan("\e_G").length)
    end

    it 'wraps escapes for tmux passthrough' do
      seq = described_class.image_escape(image, :sixel, env: { 'TMUX' => '/tmp/tmux' })
      expect(seq).to start_with("\ePtmux;\e\eP").and end_with("\e\e\\\e\\")
    end
  end
end

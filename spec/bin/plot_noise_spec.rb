require 'shellwords'

RSpec.describe('bin/plot_noise.rb') do
  def run(*args, env: {})
    text = IO.popen(env, "bin/plot_noise.rb #{args.shelljoin} 2>&1", &:read)
    expect($?).to be_success, text
    MB::U.remove_ansi(text)
  end

  # [mean, sigma, min, max, crest, kurtosis, TV distance] of a --print row
  def row(text, name)
    line = text.lines.find { |l| l.start_with?("#{name} ") }
    expect(line).not_to be_nil, text
    line.delete_prefix(name).split[0..6].map { |v| v == '-' ? nil : Float(v) }
  end

  it 'prints statistics matching the theory of each shape' do
    text = run('--print', '--seed', '1', '-n', '100000', '--only', 'uniform,sine,gauss,square,wt_saw,white')
    expect(text).to match(/^shape +mean +sigma/)

    _, sigma, min, max, _, kurt, tv = row(text, 'uniform')
    expect(sigma).to be_within(0.01).of(1 / Math.sqrt(3))
    expect([min, max]).to eq([-1, 1])
    expect(kurt).to be_within(0.05).of(1.8)
    expect(tv).to be < 0.02

    _, sigma, _, _, _, kurt, tv = row(text, 'sine')
    expect(sigma).to be_within(0.01).of(Math.sqrt(0.5))
    expect(kurt).to be_within(0.05).of(1.5)
    expect(tv).to be < 0.02
    expect(text).to match(/^sine .* arcsine$/)

    _, _, min, max, _, kurt, tv = row(text, 'gauss')
    expect(kurt).to be_within(0.3).of(3)
    expect(max - min).to be > 4
    expect(tv).to be < 0.04
    expect(text).to match(/^gauss .* Gaussian \(sigma 0\.\d+\)$/)

    _, sigma, _, _, crest, kurt, tv = row(text, 'square')
    expect(sigma).to be_within(0.01).of(1)
    expect(crest).to be_within(0.05).of(0)
    expect(tv).to be_nil

    # The exact saw series has Gibbs peaks of about 1.18
    _, _, _, max, = row(text, 'wt_saw')
    expect(max).to be_within(0.01).of(1.18)

    _, _, _, _, _, kurt, tv = row(text, 'white')
    expect(kurt).to be_within(0.1).of(3)
    expect(tv).to be < 0.02
  end

  it 'adds expressions, with a fitted Gaussian on request' do
    text = run('--print', '-n', '50000', '--only', 'none', '-G', '-e', '1.hz.ramp.noise + 1.hz.ramp.noise', '1.hz.sine.noise.at(0.5)')
    _, sigma, min, max, _, kurt, tv = row(text, 'expr 1')
    expect(sigma).to be_within(0.02).of(Math.sqrt(2.0 / 3)) # two uniforms: a triangular distribution
    expect(kurt).to be_within(0.1).of(2.4)
    expect(tv).to be_between(0.02, 0.2)
    expect(text).to match(/^expr 2 .* Gaussian/)
    expect(row(text, 'expr 2')[3]).to be_within(0.001).of(0.5)
  end

  it 'lists the shapes, including the wavetable library' do
    text = run('--list')
    expect(text).to include('uniform', 'gauss', 'sine', 'triangle', 'square', 'wt_saw', 'wt_basic', 'noise', 'white', 'pink', 'brown')
  end

  it 'plots densities with the theory in the terminal' do
    text = run('--only', 'sine,uniform', '-n', '20000', '-b', '40', env: { 'PLOT_WIDTH' => '80', 'PLOT_HEIGHT' => '20' })
    expect(text).to include('sine: 1.hz.sine.noise', 'uniform: 1.hz.ramp.noise', 'estimate', 'arcsine')
    expect(text.lines.count { |l| l.match?(/\+-{20,}\+/) }).to eq(4) # two plots, each with two borders
  end

  it 'rejects unknown shapes' do
    text = IO.popen('bin/plot_noise.rb --only bogus 2>&1', &:read)
    expect($?).not_to be_success
    expect(text).to include('Unknown shape bogus')
  end
end

RSpec.describe(MB::Term::Grid) do
  after { described_class.native = @saved }
  before { @saved = described_class.native }

  it 'makes Cells without a native grid' do
    described_class.native = nil
    expect(described_class.new(3, 2)).to be_a(MB::Term::Cells)
    expect(described_class.native?).to eq(false)
  end

  it 'makes the registered native grid unless asked for Ruby or turned off by MB_TERM_NATIVE=0' do
    klass = Class.new(MB::Term::Cells)
    described_class.native = klass
    expect(described_class.new(3, 2)).to be_a(klass)
    expect(described_class.new(3, 2, native: false).class).to eq(MB::Term::Cells)
    begin
      ENV['MB_TERM_NATIVE'] = '0'
      expect(described_class.new(3, 2).class).to eq(MB::Term::Cells)
    ensure
      ENV.delete('MB_TERM_NATIVE')
    end
  end

  it 'refuses classes without the grid interface' do
    expect { described_class.native = Class.new { def width = 1 } }.to raise_error(ArgumentError, /lacks grid methods: height, set/)
  end
end

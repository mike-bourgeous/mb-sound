RSpec.describe(EnvRestore) do
  it 'puts a deleted variable back and removes one an example added' do
    saved = { 'OUTPUT_TYPE' => 'null', 'INPUT_TYPE' => nil }
    ENV.delete('OUTPUT_TYPE')
    ENV['INPUT_TYPE'] = 'file'
    EnvRestore.restore(saved)
    expect(ENV['OUTPUT_TYPE']).to eq('null')
    expect(ENV.key?('INPUT_TYPE')).to eq(false)
  end

  it 'covers OUTPUT_TYPE around every example (the hook runs from spec_helper)' do
    expect(EnvRestore::NAMES).to include('OUTPUT_TYPE')
    expect(RSpec.configuration.hooks.send(:matching_hooks_for, :around, :example, self.class).size).to be >= 1
  end
end

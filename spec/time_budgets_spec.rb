# spec/time_budgets.yml is read by rake spec:parallel (spec/parallel_specs.rb)
# only after the whole run, so a file YAML can't load (a colon in a reason,
# 2026-11-01) would fail the run at its end; this checks it with the suite.
RSpec.describe('spec/time_budgets.yml') do
  it 'loads, and every entry names an existing spec file, numeric budgets, and a reason' do
    y = YAML.load_file(File.expand_path('time_budgets.yml', __dir__))
    expect(y['default'].values).to all(be_a(Numeric))
    y['files'].each do |path, entry|
      expect(File.exist?(File.expand_path("../#{path}", __dir__))).to eq(true), "#{path} doesn't exist"
      expect(entry.slice('file', 'example').values).to all(be_a(Numeric)), path
      expect(entry['reason']).to be_a(String).and(satisfy { |r| !r.strip.empty? }), "#{path} has no reason"
    end
  end
end

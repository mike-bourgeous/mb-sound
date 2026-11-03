# The live run with injected stalls is a smoke row (spec/bin/script_smoke_spec.rb):
# it plays a song for several seconds on the null device.
RSpec.describe('bin/dropout_probe.rb') do
  it 'refuses renders and unknown --inject kinds' do
    text, status = fork_script('bin/dropout_probe.rb', '-q', '--inject', 'gremlins')
    expect(status).not_to be_success
    expect(text).to include('Unknown --inject gremlins (render, gvl, gc, lock, system, spawn, spawn_direct, all, none)')

    text, status = fork_script('bin/dropout_probe.rb', '-q', '-o', tmp_path('x.flac'))
    expect(status).not_to be_success
    expect(text).to include('The dropout probe plays live')
  end
end

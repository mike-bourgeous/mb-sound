# ux-fix-1 item 14: README's setup drifted from the Dockerfile (packages),
# DOCKER.md mounted the repo where the image doesn't work, and the README's
# first script skeleton must run.
RSpec.describe('README and DOCKER.md') do
  root = File.expand_path('..', __dir__)
  readme = File.read(File.join(root, 'README.md'))
  dockerfile = File.read(File.join(root, 'Dockerfile'))

  it 'lists the Dockerfile\'s library packages in every apt install line' do
    wanted = %w[ffmpeg libsamplerate0-dev libasound2-dev libjack-jackd2-dev jackd2 graphviz]
    expect(dockerfile.split).to include(*wanted)
    lines = readme.lines.grep(/apt(-get)? install/)
    expect(lines.length).to be >= 2
    lines.each { |l| expect(l.split).to include(*wanted), l }
  end

  it 'compiles with bundle exec and changes directory once' do
    expect(readme).not_to match(/^rake compile/)
    expect(readme.scan(/^cd mb-sound$/).length).to eq(1)
  end

  it 'mounts the repository where the image works' do
    docker = File.read(File.join(root, 'DOCKER.md'))
    workdir = dockerfile[/^VOLUME (\S+)/, 1]
    expect(docker).to include("-v .:#{workdir} ")
  end

  it 'runs the script skeleton' do
    code = readme[/### A script\n.*?```ruby\n(.*?)```/m, 1]
    expect(code).to include('module MB::Sound')
    path = tmp_path('arp.flac')
    expect { eval(code.sub('#!/usr/bin/env ruby', '').sub("'arp.flac'", path.inspect), TOPLEVEL_BINDING) }.not_to raise_error
    expect(MB::Sound.read(path)[0].length).to be > 48000
  end
end

require 'open3'
require 'rbconfig'

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

  # (userdocs-1: the skeleton is a plain song file, `require 'mb/sound/dsl'`,
  # which changes the program's top level, so it runs as its own process,
  # as spec/lib/mb/sound/dsl_spec.rb runs song files)
  it 'runs the script skeleton' do
    code = readme[/### A script\n.*?```ruby\n(.*?)```/m, 1]
    expect(code).to include("require 'mb/sound/dsl'")
    dir = tmp_path('readme')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'arp.rb'), code)
    out, status = Open3.capture2e({ 'OUTPUT_TYPE' => 'null' }, RbConfig.ruby, '-I', File.join(root, 'lib'), 'arp.rb', chdir: dir)
    expect(status).to be_success, out
    expect(MB::Sound.read(File.join(dir, 'arp.flac'))[0].length).to be > 48000
  end

  it 'points musicians to the guide and the console help' do
    expect(readme).to include('docs/guide/README.md', '`guide`', '`help`', '`lesson`')
    expect(File).to exist(File.join(root, 'CONTRIBUTING.md'))
  end
end

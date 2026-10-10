RSpec.describe('bin/matrix_process.rb') do
  let(:test_out) { tmp_path('matrix_process_test.flac') }
  let(:qs_out) { tmp_path('matrix_process_qs.flac') }
  let(:qs_enc_out) { tmp_path('matrix_process_qs_enc.flac') }

  # Runs the script in a fork (see ForkScript), returning its output; the
  # first example is the real-process run.
  def run(*args)
    text, @status = fork_script('bin/matrix_process.rb', *args)
    text
  end

  it 'can convert a 2ch file to a 4ch file' do
    text = `bin/matrix_process.rb spec/test_data/arp_a7.flac matrices/hafler.yml #{test_out.shellescape}`
    expect($?).to be_success
    expect(text).to include('Success')

    in_info = MB::Sound::FFMPEGInput.parse_info('spec/test_data/arp_a7.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info(test_out)

    expect(out_info[:streams][0][:channels]).to eq(4)
    expect(out_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])
  end

  it 'can decode and re-encode using an included complex-valued matrix' do
    text = run('--decode', 'spec/test_data/arp_a7.flac', 'qs.yml', qs_out)
    expect(@status).to be_success
    expect(text).to include('included matrix')
    expect(text).to include('Success')

    in_info = MB::Sound::FFMPEGInput.parse_info('spec/test_data/arp_a7.flac')
    out_info = MB::Sound::FFMPEGInput.parse_info(qs_out)

    expect(out_info[:streams][0][:channels]).to eq(4)
    expect(out_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])

    text = run(qs_out, 'qs.yml', qs_enc_out)
    expect(@status).to be_success
    expect(text).to include('included matrix')
    expect(text).to include('Success')

    enc_info = MB::Sound::FFMPEGInput.parse_info(qs_enc_out)

    expect(enc_info[:streams][0][:channels]).to eq(2)
    expect(enc_info[:streams][0][:duration_ts]).to eq(in_info[:streams][0][:duration_ts])
  end

  it 'lists included matrices when given the --list flag' do
    text = run('--list')
    expect(@status).to be_success
    expect(text).to include('Built-in matrices')
    expect(text).to include('hafler.yml')
    expect(text).to include('qs.yml')
    expect(text).to include('sq.yml')
    expect(text).to match(%r{dynaquad/encode.yml.*4.*2.*Dynaquad.*quadraphonic})
    expect(text).to match(%r{dynaquad/decode.yml.*2.*4.*Dynaquad.*quadraphonic})
  end

  it 'shows matrix details when given the --show flag' do
    text = MB::U.remove_ansi(run('--show', 'qs.yml'))
    expect(@status).to be_success
    lines = text.lines
    expect(lines).not_to include(match(/Transposing.*decoding/))
    expect(lines).to include(match(/QS Regular Matrix/))
    expect(lines).to include(match(/Coefficients are from/))
    expect(lines).to include(match(/FL.*FR.*RL.*RR/))
    expect(lines).to include(match(/Lt.*0.924.*0.383.*0.924i.*0.383i/))
  end

  it 'can show a transposed matrix with the --show and --decode flags' do
    text = MB::U.remove_ansi(run('--show', '--decode', 'qs.yml'))
    expect(@status).to be_success
    lines = text.lines
    expect(lines).to include(match(/Transposing.*decoding/))
    expect(lines).to include(match(/QS Regular Matrix/))
    expect(lines).to include(match(/Coefficients are from/))
    expect(lines).to include(match(/Lt.*Rt/))
    expect(lines).to include(match(/FL.*0.924.*0.383/))
    expect(lines).to include(match(/RR.*0-0.383i.*0\+0.924i/))
    expect(lines).not_to include(match(/Lt.*0.924.*0.383.*0.924i.*0.383i/))
  end
end

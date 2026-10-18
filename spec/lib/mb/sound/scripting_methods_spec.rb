RSpec.describe(MB::Sound::ScriptingMethods) do
  # Every script helper (effect_script, synth_script, song_script, script)
  # turns errors about the script's inputs or the sound card into one line
  # and exit status 2 through the same ScriptingMethods#script_errors
  # (ux-fix-2: plain `script` scripts printed a 30-frame backtrace for
  # DeviceOutput::Unavailable).  A new helper is picked up by its name.
  describe 'script error handling' do
    helpers = MB::Sound::ScriptingMethods.public_instance_methods(false).grep(/script\z/).sort

    it 'finds every helper' do
      expect(helpers).to include(:effect_script, :synth_script, :song_script, :script)
    end

    errors = {
      'no sound card' => [MB::Sound::DeviceOutput::Unavailable, 'No audio output device (test)'],
      'an input error' => [MB::Sound::ScriptRunner::InputError, 'no file "nosuch.flac"'],
      'a render window error' => [MB::Sound::RenderWindow::TargetError, '--from no section :drp'],
      'a misspelled device' => [MB::Sound::DeviceOutput::NoSuchDevice, 'No output device matches "x"'],
    }

    it 'covers every error class it prints' do
      expect(MB::Sound::ScriptingMethods.script_errors).to match_array(errors.values.map(&:first))
    end

    helpers.each do |helper|
      kind = helper == :script ? :script : helper.to_s.delete_suffix('_script').to_sym

      errors.each do |what, (klass, message)|
        it "#{helper} prints #{what} without a backtrace and exits 2" do
          stub_const('ARGV', [])
          allow_any_instance_of(MB::Sound::ScriptRunner).to receive(:"run_#{kind}").and_raise(klass, message)

          status = nil
          expect {
            begin
              MB::Sound.public_send(helper) { |*| }
            rescue SystemExit => e
              status = e.status
            end
          }.to output("#{File.basename($0)}: #{message}\n").to_stderr

          expect(status).to eq(2)
        end
      end
    end
  end
end
